# ChipCraft Lab — How It Works

## Overview

ChipCraft is a browser-based VLSI lab platform. Students log in with GitHub, get a
private Linux desktop (XFCE + VNC) in their browser, and work with Verilog files
using Verilator, iverilog, and GTKWave — without installing anything locally.

The Verilog lab files are **encrypted at rest**. Students can edit and compile them
inside the container, but they cannot extract the plaintext or the encryption key.

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  TEACHER'S PC                                                       │
│                                                                     │
│  counter.v  ──encrypt──►  counter.v.enc  ──push──►  GitHub Repo   │
│  (private)    encrypt_lab.sh   (safe to share)                     │
└─────────────────────────────────────────────────────────────────────┘
                                                          │
                                                    git clone (fork)
                                                          │
┌─────────────────────────────────────────────────────────────────────┐
│  SERVER  (docker compose up)                                        │
│                                                                     │
│  ┌──────────────┐        ┌──────────────────────────────────────┐  │
│  │  API Service │        │  Student Container (per student)     │  │
│  │  port 80     │        │                                      │  │
│  │              │        │  ~/lab/          (git clone, rw)     │  │
│  │  CHIPCRAFT   │◄──────►│    counter.v.enc                     │  │
│  │  _KEY in     │one-time│                                      │  │
│  │  memory only │ token  │  ~/labs/         (tmpfs, RAM only)   │  │
│  │              │        │    counter.v     ← student edits     │  │
│  │  GitHub      │        │    Makefile                          │  │
│  │  OAuth login │        │                                      │  │
│  └──────────────┘        │  Browser VNC desktop (noVNC:6080)   │  │
│                           └──────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                              Student's browser
                         (sees XFCE desktop via noVNC)
```

---

## Components

| File / Service | Role |
|---|---|
| `tools/encrypt_lab.sh` | Teacher runs this on their PC to encrypt `.v` files |
| `tools/decrypt_watch.sh` | Runs inside container — decrypts on startup, re-encrypts on save |
| `tools/watermark.py` | Embeds/reads invisible trailing-space watermark in `.v` files |
| `tools/detect_leak.sh` | Teacher tool — identifies which student a leaked file came from |
| `api/main.py` | FastAPI service — GitHub OAuth, container launch, key delivery |
| `router/app.py` | Simple load balancer across student containers |
| `Dockerfile` | Builds the student desktop image (XFCE + VNC + Verilator + iverilog) |
| `entrypoint.sh` | Container startup — starts VNC, noVNC, egress firewall, decrypt_watch |
| `.env` | Server-side secrets (never committed, never shared) |

---

## Encryption — Teacher Side

### The Key

The encryption key is an AES-256 passphrase set by the teacher.  
It lives in **two places only**:

1. The teacher's terminal (as `CHIPCRAFT_KEY` env var) when encrypting
2. The server's `.env` file (so the API can deliver it to containers)

It is **never** stored in:
- The Docker image
- The GitHub repository
- The student container's environment

### Encrypting Files

```bash
# On teacher's PC (Git Bash / WSL / Mac / Linux)

export CHIPCRAFT_KEY="your-secret-key"

# Encrypt a single file
bash NVR/tools/encrypt_lab.sh counter.v
# → counter.v.enc

# Encrypt all .v files in a folder
bash NVR/tools/encrypt_lab.sh NVR/chipcraft-student/
# → creates .v.enc for every .v file
```

`encrypt_lab.sh` uses **AES-256-CBC with PBKDF2** (via openssl):

```
openssl enc -aes-256-cbc -pbkdf2 -salt -k "$KEY" -in counter.v -out counter.v.enc
```

### Pushing to GitHub

Only encrypted files go to GitHub. The `.gitignore` in `chipcraft-student/` ensures this:

```
*.v        ← blocked (plaintext, never committed)
!*.v.enc   ← allowed (encrypted, safe to share)
```

```bash
cd NVR/chipcraft-student
git add *.v.enc Makefile .gitignore
git commit -m "lab1: counter"
git push
```

---

## Key Delivery — How the Container Gets the Key

The key never travels directly to the student container.  
It is delivered via a **one-time bootstrap token** over the internal Docker network.

### Step-by-step

```
1. Teacher sets CHIPCRAFT_KEY in .env on server
            │
2. docker compose up  →  API container reads CHIPCRAFT_KEY into memory
            │
3. Student logs in via GitHub OAuth
            │
4. API generates a BOOTSTRAP_TOKEN  (32 random bytes, expires in 30 seconds)
            │
5. API launches student container with BOOTSTRAP_TOKEN in its environment
   (CHIPCRAFT_KEY is NOT passed to the container)
            │
6. Container starts → decrypt_watch.sh runs immediately
            │
7. decrypt_watch.sh calls:
   POST http://api:8000/lab-key   { "token": "<BOOTSTRAP_TOKEN>" }
   (over internal Docker network — not reachable from student's browser)
            │
8. API validates the token:
   - Is the caller on the internal Docker network? (IP check)
   - Is the token valid and not expired?
   - Marks the token as used (single-use — works only once)
            │
9. API returns CHIPCRAFT_KEY in the response
            │
10. decrypt_watch.sh stores the key in a bash variable
    BOOTSTRAP_TOKEN is immediately unset from the environment
            │
11. openssl decrypts counter.v.enc → counter.v  (into tmpfs RAM)
            │
12. Student opens ~/labs/counter.v  — sees plain Verilog
```

### Why students cannot steal the key

| Attack | Blocked because |
|---|---|
| `env` in terminal | `BOOTSTRAP_TOKEN` already consumed and unset; `CHIPCRAFT_KEY` was never there |
| `curl http://api:8000/lab-key` from terminal | Token is already used (single-use); a new call returns 401 |
| Copy `.v.enc` file home and decrypt | They don't have the key |
| Read `.env` file | It's on the server — not inside the container |
| `docker inspect api` | Requires Docker daemon access — students don't have it |

---

## Decryption — Inside the Container

`decrypt_watch.sh` runs as a background process inside every student container.

### On container startup

```
~/lab/counter.v.enc   (git clone)
         │
         │  openssl dec -k "$KEY"
         ▼
~/labs/counter.v      (tmpfs — RAM only, never touches disk)
~/labs/Makefile       (copied from ~/lab/)
```

### On every student save

```
Student saves ~/labs/counter.v
         │
         │  inotifywait detects close_write / moved_to
         ▼
openssl enc -k "$KEY"
         │
         ▼
~/lab/counter.v.enc   (updated on the persistent volume)
```

This means:
- The student edits **decrypted** `.v` files normally
- The **encrypted** `.v.enc` files are always kept up to date automatically
- If the container restarts, files are re-decrypted from the `.v.enc` backup

### tmpfs — why it matters

`/home/ubuntu/labs` is a **RAM-only filesystem** (tmpfs, 100 MB).

- Decrypted `.v` files exist **only in memory** while the container runs
- When the container stops, they vanish automatically
- No plaintext is ever written to the host disk or the Docker volume

### Which files get re-encrypted on save — and from where?

`decrypt_watch.sh` watches the **entire home directory** (`~/`) recursively.
This means a student can save or edit a lab file from **any folder** and
re-encryption still triggers automatically.

> **A `.v` file is re-encrypted only if a matching `.v.enc` already exists in `~/lab/`.**

This means student-created files and files copied from other sources are
**never encrypted** — they are saved as plain `.v` files and left alone.

| File saved (any location) | `~/lab/*.v.enc` exists? | Action |
|---|---|---|
| `counter.v` (teacher lab file) | Yes | Re-encrypted → `~/lab/counter.v.enc` ✓ |
| `tb_counter.v` (teacher lab file) | Yes | Re-encrypted → `~/lab/tb_counter.v.enc` ✓ |
| `my_adder.v` (student's own file) | No | Left as plain `.v` — no encryption ✓ |
| `copied_example.v` (from internet) | No | Left as plain `.v` — no encryption ✓ |

```
# Re-encryption triggered regardless of where the student saves from:
vim ~/labs/counter.v          → re-encrypted ✓   (saved inside ~/labs/)
vim ~/counter.v               → re-encrypted ✓   (saved in home dir)
cp ~/labs/counter.v ~/work/counter.v
vim ~/work/counter.v          → re-encrypted ✓   (saved in ~/work/)

# Student's own files — never encrypted, wherever they are:
vim ~/labs/my_adder.v         → plain .v, skipped ✓
vim ~/my_adder.v              → plain .v, skipped ✓
```

### Compiling from any folder

The `Makefile` automatically finds `.v` files in `~/labs/` regardless of
which directory the student's terminal is in:

```bash
# All of these work identically
cd ~/labs  && make
cd ~       && make -f ~/labs/Makefile
cd ~/work  && make -f ~/labs/Makefile

# Or point to a different folder
make LABS=~/myfolder
```

---

## Student Workflow

### 1. Login

Student visits the lab URL → clicks **Login with GitHub** → OAuth → portal page.

### 2. Launch Lab

Clicks **Launch ChipCraft Lab**:
- API forks the template repo into the student's GitHub account
- Launches a personal container
- Redirects to the XFCE desktop in the browser (noVNC)

### 3. Compile and Simulate

Student opens **XFCE Terminal**:

```bash
cd ~/labs

make              # compile + simulate
make wave         # compile + simulate + open GTKWave
make clean        # remove build outputs
```

What `make` does internally:

```bash
iverilog -g2012 -Wall -o sim.vvp tb_counter.v counter.v
vvp sim.vvp
# → prints simulation output
# → writes counter.vcd
gtkwave counter.vcd   # (make wave only)
```

### 4. Save Work to GitHub

```bash
cd ~/lab
git add *.v.enc
git commit -m "my solution"
git push
# ✓ Work saved — only encrypted files go to GitHub
```

---

## Server Setup (Teacher)

### 1. Create `.env` on the server

```bash
# NVR/.env   (never commit this file)
CHIPCRAFT_KEY=your-secret-key-here
GH_CLIENT_ID=your_github_oauth_app_id
GH_CLIENT_SECRET=your_github_oauth_secret
VNC_PASSWORD=novnc
SHARED_PATH=/data/workspace/project
TEMPLATE_REPO=your-github-username/chipcraft-student
SESSION_TTL=14400
PORT_START=6081
PORT_END=6180
```

### 2. Build and start

```bash
cd NVR
docker compose build   # builds ubuntu-novnc:latest image
docker compose up -d   # starts the API service
```

### 3. Add lab files

```bash
# Encrypt on your PC, push to GitHub (see Encryption section above)
# The API will fork + clone the repo automatically for each student
```

---

## File Layout Inside the Container

```
/home/ubuntu/
├── lab/                  ← git clone of student's forked repo (persistent volume)
│   ├── counter.v.enc     ← encrypted (updated on every student save)
│   ├── tb_counter.v.enc
│   ├── Makefile
│   └── .gitignore
│
├── labs/                 ← tmpfs (RAM only — cleared on container stop)
│   ├── counter.v         ← decrypted, student edits here
│   ├── tb_counter.v
│   ├── Makefile          ← copied from ~/lab at startup
│   ├── sim.vvp           ← generated by iverilog
│   └── counter.vcd       ← generated by simulation, opened in GTKWave
│
└── shared/               ← read-only mount from server (fallback source)
    └── *.v.enc
```

---

## File Exfiltration — Possible Attack Paths

Even with decryption protection, a student who can see and run the file might
try to copy the plaintext out of the container. Here is every known method and
whether it is blocked:

| Attack method | Blocked? | How |
|---|---|---|
| **noVNC clipboard** — copy text from editor via the clipboard button | ✅ Blocked | `-noclipboard` flag on vncserver |
| **git push decrypted files** from `~/labs/` | ✅ Blocked | No `.git` in `~/labs/`; `*.v` in `.gitignore` |
| **curl / wget** to paste sites (HTTP/HTTPS) | ✅ Blocked | Egress firewall — only GitHub IPs allowed |
| **Browser inside VNC** → Google Drive, email, upload | ✅ Blocked | Egress firewall |
| **docker cp** from host | Admin only | Requires Docker daemon access — students don't have it |
| **Phone photo / screen recording** | ❌ Cannot block | Watermark identifies the student |
| **Manual typing** the code out | ❌ Cannot block | Watermark + academic integrity policy |

---

## Watermarking — Tracing Leaked Files

Every decrypted `.v` file receives two watermarks:

### Visible watermark (decoy)
A comment at the top of the file — obvious, easy to delete:
```verilog
// [ChipCraft] Student: @john_student | 2026-06-19
module counter #( ...
```

### Invisible watermark (real trap)
The student's GitHub username is encoded as **binary bits into trailing spaces**
on each line — completely invisible to readers and editors:

```
module counter #(·      ← trailing space = bit 1
    parameter WIDTH = 4 ← no trailing space = bit 0
)(·                     ← trailing space = bit 1
    ...                 ← encodes "john_student" across all lines
```

When the student deletes the visible comment thinking the watermark is gone,
the invisible one is still present. It survives copy-paste, editor saves,
and sharing the file online.

### How to detect a leaked file (teacher)

```bash
# On teacher's PC — works on plain .v or encrypted .v.enc files
export CHIPCRAFT_KEY="your-secret-key"

bash tools/detect_leak.sh leaked_counter.v
# → Leaked file : leaked_counter.v
# → Student     : @john_student

bash tools/detect_leak.sh counter.v.enc   # auto-decrypts first
# → Leaked file : counter.v.enc
# → Student     : @john_student
```

---

## Egress Firewall

Each student container starts with iptables rules that block all outbound
internet traffic except what the lab needs:

```
ALLOWED outbound:
  ├── Loopback (127.0.0.1)
  ├── Docker internal network (172.x, 10.x)  ← for API key delivery
  ├── DNS (port 53)
  └── GitHub IP ranges (port 443 / 22)       ← for git push only

BLOCKED outbound:
  └── Everything else — paste sites, email, file sharing, cloud storage
```

Students can still `git push` their encrypted work to their GitHub repo,
but cannot upload the decrypted `.v` files to any external service.

---

## Security Summary

```
CHIPCRAFT_KEY journey:
  .env (server, teacher-only access)
    → API container memory only
      → POST /lab-key (internal Docker network, one-time token, 30s TTL)
        → bash variable in decrypt_watch.sh (~2 seconds)
          → openssl stdin  →  GONE

Decrypted .v files:
  ~/labs/ (tmpfs, RAM only)  →  watermarked  →  GONE when container stops

Encrypted .v.enc files:
  GitHub + ~/lab/ volume  →  safe to store anywhere  →  useless without key

If a file leaks:
  tools/detect_leak.sh  →  reads invisible trailing-space watermark  →  names the student
```
