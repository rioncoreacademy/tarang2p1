# ChipCraft Lab — How It Works

## Overview

ChipCraft is a browser-based VLSI lab platform. Students log in with GitHub, get a
private Linux desktop (XFCE + VNC) in their browser, and work with Verilog files
using Verilator, iverilog, and GTKWave — without installing anything locally.

The Verilog lab files are **encrypted at rest**. Students can edit and compile them
inside the container, but they cannot extract the plaintext or the encryption key.

---

## GitHub Repositories

| Repo | URL | Purpose |
|---|---|---|
| `chipcraft-lab` | github.com/narrave/chipcraft-lab | Infrastructure — Dockerfile, API, entrypoint, tools |
| `chipcraft-lab-files` | github.com/narrave/chipcraft-lab-files | Lab files — encrypted `.v.enc` files + Makefile |
| `chipcraft-student` | github.com/narrave/chipcraft-student | VS Code Codespace launch only (devcontainer) |

> **`chipcraft-lab-files` is the template repo.** The API forks it into each student's
> GitHub account when they log in. Students clone their own fork and push encrypted
> work back to it.

---

## System Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│  TEACHER'S PC                                                            │
│                                                                          │
│  counter.v  ──encrypt──►  counter.v.enc  ──push──►  chipcraft-lab-files │
│  (private)    encrypt_lab.sh   (safe to share)      github.com/narrave   │
└──────────────────────────────────────────────────────────────────────────┘
                                                              │
                                              API forks repo per student
                                              Student's fork cloned → ~/lab/
                                                              │
┌──────────────────────────────────────────────────────────────────────────┐
│  SERVER  (docker compose up)                                             │
│                                                                          │
│  ┌──────────────┐        ┌───────────────────────────────────────────┐  │
│  │  API Service │        │  Student Container (one per student)      │  │
│  │  port 80     │        │                                           │  │
│  │              │        │  ~/lab/            (student's git fork)   │  │
│  │  CHIPCRAFT   │◄──────►│    counter.v.enc   ← re-encrypted on save │  │
│  │  _KEY in     │one-time│    tb_counter.v.enc                       │  │
│  │  memory only │ token  │    Makefile                               │  │
│  │              │        │                                           │  │
│  │  GitHub      │        │  ~/labs/           (tmpfs — RAM only)     │  │
│  │  OAuth login │        │    counter.v       ← student edits here   │  │
│  └──────────────┘        │    tb_counter.v                           │  │
│                           │    Makefile                               │  │
│                           │                                           │  │
│                           │  Browser VNC desktop (noVNC port 6080)   │  │
│                           └───────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
                                       │
                                 Student's browser
                          (sees XFCE desktop via noVNC)
```

---

## Components

| File / Service | Repo | Role |
|---|---|---|
| `tools/encrypt_lab.sh` | chipcraft-lab | Teacher encrypts `.v` files on their PC |
| `tools/decrypt_watch.sh` | chipcraft-lab | Container — decrypts on startup, re-encrypts on save |
| `tools/watermark.py` | chipcraft-lab | Embeds / reads invisible trailing-space watermark |
| `tools/detect_leak.sh` | chipcraft-lab | Teacher tool — identifies student from a leaked file |
| `api/main.py` | chipcraft-lab | FastAPI — GitHub OAuth, container launch, key delivery |
| `router/app.py` | chipcraft-lab | Load balancer across student containers |
| `Dockerfile` | chipcraft-lab | Builds student desktop image (XFCE + VNC + Verilator) |
| `entrypoint.sh` | chipcraft-lab | Container startup — VNC, firewall, decrypt_watch |
| `docker-compose.yml` | chipcraft-lab | Defines API service and build targets |
| `.env` | server only | Server-side secrets — never committed |
| `*.v.enc` | chipcraft-lab-files | Encrypted Verilog lab files |
| `Makefile` | chipcraft-lab-files | `make` / `make wave` / `make clean` |
| `.gitignore` | chipcraft-lab-files | Blocks `*.v`, allows `*.v.enc` |

---

## Encryption — Teacher Side

### The Key

The encryption key is an AES-256 passphrase set by the teacher.
It lives in **two places only**:

1. The teacher's terminal (`CHIPCRAFT_KEY` env var) when encrypting
2. The server's `.env` file (so the API can deliver it to containers at runtime)

It is **never** stored in:
- The Docker image
- Any GitHub repository
- The student container's environment

### Encrypting Files

```bash
# On teacher's PC (Git Bash / WSL / Mac / Linux)
export CHIPCRAFT_KEY="your-secret-key"

# Encrypt a single file
bash NVR/tools/encrypt_lab.sh counter.v
# → counter.v.enc

# Encrypt all .v files in a folder at once
bash NVR/tools/encrypt_lab.sh labs/
# → creates .v.enc for every .v file in that folder
```

`encrypt_lab.sh` uses **AES-256-CBC with PBKDF2** (openssl):

```
openssl enc -aes-256-cbc -pbkdf2 -salt -k "$KEY" -in counter.v -out counter.v.enc
```

### Pushing Encrypted Files to chipcraft-lab-files

Only encrypted files go to GitHub. The `.gitignore` blocks plaintext:

```
*.v        ← blocked  (plaintext — never committed)
!*.v.enc   ← allowed  (encrypted — safe to share)
```

```bash
cd chipcraft-lab-files

# Copy encrypted files here, then push
cp ../labs/*.v.enc .
git add *.v.enc
git commit -m "lab1: counter"
git push
# → github.com/narrave/chipcraft-lab-files now has counter.v.enc
```

### Adding More Lab Files Later

```bash
cd chipcraft-lab-files

bash ../NVR/tools/encrypt_lab.sh adder.v   # → adder.v.enc
rm adder.v                                 # never commit plaintext
git add adder.v.enc
git commit -m "lab2: adder"
git push
# Students get the new file on their next container restart
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
4. API forks chipcraft-lab-files → student's GitHub account
   API clones student's fork    → ~/lab/ inside the container
            │
5. API generates BOOTSTRAP_TOKEN (32 random bytes, expires in 30 seconds)
   API launches student container with BOOTSTRAP_TOKEN in its environment
   (CHIPCRAFT_KEY is NOT passed to the student container)
            │
6. Container starts → decrypt_watch.sh runs immediately
            │
7. decrypt_watch.sh calls:
   POST http://api:8000/lab-key  { "token": "<BOOTSTRAP_TOKEN>" }
   (over internal Docker network — not reachable from student's browser)
            │
8. API validates the token:
   - Is the caller on the internal Docker network? (IP check)
   - Is the token valid and not expired?
   - Marks the token as consumed (single-use — works only once)
            │
9. API returns CHIPCRAFT_KEY in the response
            │
10. decrypt_watch.sh stores the key in a bash variable
    BOOTSTRAP_TOKEN is immediately unset from the environment
            │
11. openssl decrypts ~/lab/counter.v.enc → ~/labs/counter.v  (tmpfs RAM)
    Invisible watermark embedded in the decrypted file
            │
12. Student opens ~/labs/counter.v — sees plain Verilog, starts working
```

### Why students cannot steal the key

| Attack | Blocked because |
|---|---|
| `env` in terminal | `BOOTSTRAP_TOKEN` already consumed and unset; `CHIPCRAFT_KEY` was never there |
| `curl http://api:8000/lab-key` | Token already used — returns 401 |
| Copy `.v.enc` file and decrypt | They don't have the key |
| Read `.env` file | On the server — not inside the container |
| `docker inspect api` | Requires Docker daemon access — students don't have it |

---

## Decryption — Inside the Container

`decrypt_watch.sh` runs as a background process inside every student container.

### On container startup

```
~/lab/counter.v.enc       (student's forked git repo, cloned by API)
         │
         │  openssl dec -k "$KEY"
         │  watermark.py encode "@github_user"
         ▼
~/labs/counter.v          (tmpfs — RAM only, never touches disk)
~/labs/tb_counter.v
~/labs/Makefile           (copied from ~/lab/)
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
~/lab/counter.v.enc       (updated in student's forked repo)
         │
         ▼
cd ~/lab && git push      (student saves encrypted work to their GitHub fork)
```

### tmpfs — why it matters

`/home/ubuntu/labs` is a **RAM-only filesystem** (tmpfs, 100 MB).

- Decrypted `.v` files exist **only in memory** while the container runs
- When the container stops, they vanish automatically
- No plaintext is ever written to the host disk or the Docker volume

### Which files get re-encrypted on save

`decrypt_watch.sh` watches the **entire home directory** recursively.
A `.v` file is **only re-encrypted if a matching `.v.enc` already exists in `~/lab/`**.
Student-created files and files from other sources are left as plain `.v`.

| File saved | `~/lab/*.v.enc` exists? | Action |
|---|---|---|
| `counter.v` (teacher lab file) | Yes | Re-encrypted → `~/lab/counter.v.enc` ✓ |
| `tb_counter.v` (teacher lab file) | Yes | Re-encrypted → `~/lab/tb_counter.v.enc` ✓ |
| `my_adder.v` (student's own file) | No | Left as plain `.v` — not encrypted ✓ |
| `copied_example.v` (from internet) | No | Left as plain `.v` — not encrypted ✓ |

### Compiling from any folder

```bash
cd ~/labs && make              # compile + simulate
cd ~      && make              # also works — Makefile finds ~/labs/ automatically
make wave                      # compile + simulate + open GTKWave
make clean                     # remove sim.vvp and .vcd files
make LABS=~/myfolder           # point to a different folder
```

---

## Student Workflow

### 1. Login

Student visits the lab URL → clicks **Login with GitHub** → OAuth → portal page.

### 2. Launch Lab

Clicks **Launch ChipCraft Lab**:
- API forks `chipcraft-lab-files` into the student's GitHub account
- Launches a personal container and clones the student's fork into `~/lab/`
- Redirects to the XFCE desktop in the browser (noVNC)
- `decrypt_watch.sh` decrypts lab files into `~/labs/` (RAM)

### 3. Edit and Compile

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
# → prints simulation output + writes counter.vcd
gtkwave counter.vcd   # (make wave only)
```

### 4. Save Work to GitHub

```bash
cd ~/lab
git add *.v.enc
git commit -m "lab1 solution"
git push
# ✓ Encrypted work saved to student's personal fork on GitHub
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
TEMPLATE_REPO=narrave/chipcraft-lab-files
SESSION_TTL=14400
PORT_START=6081
PORT_END=6180
```

### 2. Get the Docker image (GitHub Actions builds it automatically)

Every push to `master` that touches `Dockerfile`, `entrypoint.sh`, or
`tools/decrypt_watch.sh` triggers **GitHub Actions → Publish Docker Image**
which builds and pushes `ghcr.io/narrave/chipcraft:latest` automatically.

You never need to build on the server. Just pull the pre-built image:

```bash
# Pull the image GitHub Actions already built
docker pull ghcr.io/narrave/chipcraft:latest

# Tag it as the name the API expects
docker tag ghcr.io/narrave/chipcraft:latest ubuntu-novnc:latest

# Start only the API service (the student containers are spawned dynamically)
cd NVR
docker compose up -d
```

When you push a code change, GitHub Actions rebuilds the image automatically.
To roll out the new image to the server:

```bash
docker pull ghcr.io/narrave/chipcraft:latest
docker tag  ghcr.io/narrave/chipcraft:latest ubuntu-novnc:latest
# New student containers will use the updated image automatically.
# Existing running containers are not affected until they are restarted.
```

### 3. Push encrypted lab files

```bash
# Encrypt on your PC
export CHIPCRAFT_KEY="your-secret-key-here"
bash NVR/tools/encrypt_lab.sh counter.v     # → counter.v.enc
bash NVR/tools/encrypt_lab.sh tb_counter.v  # → tb_counter.v.enc

# Push to chipcraft-lab-files
cd chipcraft-lab-files
cp ../counter.v.enc ../tb_counter.v.enc .
git add *.v.enc
git commit -m "lab1: counter"
git push
# Students now get these files automatically on their next login
```

---

## File Layout Inside the Container

```
/home/ubuntu/
│
├── lab/                   ← student's forked git repo (persistent Docker volume)
│   ├── counter.v.enc      ← re-encrypted on every student save
│   ├── tb_counter.v.enc
│   ├── Makefile
│   └── .gitignore
│
└── labs/                  ← tmpfs (RAM only — vanishes when container stops)
    ├── counter.v          ← decrypted, watermarked — student edits here
    ├── tb_counter.v
    ├── Makefile           ← copied from ~/lab/ at startup
    ├── sim.vvp            ← generated by iverilog
    └── counter.vcd        ← generated by simulation, opened in GTKWave
```

---

## File Exfiltration — Possible Attack Paths

| Attack method | Blocked? | How |
|---|---|---|
| **noVNC clipboard** — copy text via the clipboard button | ✅ Blocked | `-noclipboard` on vncserver |
| **git push decrypted files** from `~/labs/` | ✅ Blocked | No `.git` in `~/labs/`; `*.v` in `.gitignore` |
| **curl / wget** to paste sites | ✅ Blocked | Egress firewall — only GitHub IPs allowed |
| **Browser inside VNC** → Google Drive, email | ✅ Blocked | Egress firewall |
| **docker cp** from host | Admin only | Requires Docker daemon access — students don't have it |
| **Phone photo / screen recording** | ❌ Cannot block | Watermark identifies the student |
| **Manual typing** the code | ❌ Cannot block | Watermark + academic integrity policy |

---

## Watermarking — Tracing Leaked Files

Every decrypted `.v` file receives two watermarks automatically.
The student's GitHub username (from `GITHUB_USER` env var set by the API) is
embedded uniquely per container — no manual step needed.

### Visible watermark (decoy)

A Verilog comment at the top — easy to spot and delete:
```verilog
// [ChipCraft] Student: @john_student | 2026-06-19
module counter #( ...
```

### Invisible watermark (real trap)

The student's GitHub username is encoded as **binary bits into trailing spaces**
on each line — completely invisible to readers and most editors:

```
module counter #(·      ← trailing space  = bit 1
    parameter WIDTH = 4 ← no trailing space = bit 0
)(·                     ← trailing space  = bit 1
    ...                 ← encodes "john_student" in binary across all lines
```

When the student deletes the visible comment line thinking the watermark is removed,
the invisible one is still present. It survives copy-paste, saves, and online sharing.

### How watermarks are applied per student

```
Student A logs in                    Student B logs in
API sets GITHUB_USER=alice           API sets GITHUB_USER=bob
        │                                    │
        ▼                                    ▼
watermark.py encode "alice"          watermark.py encode "bob"
        │                                    │
        ▼                                    ▼
~/labs/counter.v                     ~/labs/counter.v
// [ChipCraft] @alice | ...          // [ChipCraft] @bob | ...
module counter #(·  ← alice bits    module counter #(   ← bob bits
```

### How to detect a leaked file (teacher tool)

```bash
# Works on plaintext .v or encrypted .v.enc
export CHIPCRAFT_KEY="your-secret-key"

bash NVR/tools/detect_leak.sh leaked_counter.v
# → Leaked file : leaked_counter.v
# → Student     : @john_student

bash NVR/tools/detect_leak.sh counter.v.enc    # auto-decrypts first
# → Leaked file : counter.v.enc
# → Student     : @john_student
```

---

## Egress Firewall

Each student container starts with iptables rules blocking all outbound traffic
except what the lab needs:

```
ALLOWED outbound:
  ├── Loopback (127.0.0.1)
  ├── Docker internal network (172.x, 10.x)   ← API key delivery
  ├── DNS (port 53)
  └── GitHub IP ranges (port 443 / 22)        ← git push / git clone only

BLOCKED outbound:
  └── Everything else — paste sites, email, file sharing, cloud storage
```

Students can `git push` encrypted work to their GitHub fork but cannot upload
decrypted `.v` files to any external service.

---

## Security Summary

```
CHIPCRAFT_KEY journey:
  .env (server — teacher access only)
    → API container memory
      → POST /lab-key (internal network, one-time token, 30s TTL)
        → bash variable in decrypt_watch.sh (~2 seconds)
          → openssl stdin  →  GONE

Decrypted .v files:
  ~/labs/ (tmpfs, RAM only)  →  watermarked per student  →  GONE when container stops

Encrypted .v.enc files:
  chipcraft-lab-files repo + ~/lab/ volume  →  safe anywhere  →  useless without key

If a file leaks:
  detect_leak.sh  →  reads invisible trailing-space watermark  →  names the student
```
