# Tarang2_dp1 — Single-User Setup

Each student gets their own isolated Codespace with a full XFCE4 desktop running in the browser via noVNC.

## How It Works

```
Student opens repo → creates Codespace → XFCE4 desktop opens on port 6080
```

- The devcontainer pulls `ghcr.io/rioncoreacademy/tarang2p1:v1.1` from GitHub Container Registry
- `start.sh` launches TightVNC + websockify inside the container
- Port 6080 is forwarded by Codespaces and opens automatically in the browser
- No login required — password is `novnc`

## Files

| File | Purpose |
|------|---------|
| `devcontainer.json` | Codespaces config — image, port forwarding, startup command |
| `start.sh` | Starts VNC server and websockify on container boot |

## Student Instructions

1. Go to `https://github.com/rioncoreacademy/tarang2p1`
2. Click **Code → Codespaces → Create codespace on main**
3. When prompted, select **"Tarang2_dp1 — Digital Design & VLSI"**
4. Wait ~2 minutes for the container to start
5. Port 6080 opens automatically → click **Connect**
6. Enter password: `novnc`
7. XFCE4 desktop is ready

## Requirements

- Each student needs a **GitHub account**
- The repo must be **public** (or students added as collaborators)
- The GHCR image `ghcr.io/rioncoreacademy/tarang2p1` must be **public**

## How to Make Repo & Image Public

**Repo:**
GitHub → repo Settings → scroll to Danger Zone → **Change visibility → Public**

**GHCR Image:**
GitHub → your profile → Packages → `tarang2p1` → Package Settings → **Change visibility → Public**

## How Many Students

Each student runs their **own Codespace** — no sharing, no conflicts.

| GitHub Plan | Free compute hours/month | Storage |
|-------------|--------------------------|---------|
| Free | 120 hours | 15 GB |
| Pro ($4/month) | 180 hours | 20 GB |

Each Codespace runs independently so there is no limit on number of students — each uses their own GitHub account's quota.

## Docker Image

The image is built automatically by GitHub Actions when the `Dockerfile` changes.
Pin to a version tag rather than `:latest` (which moves on every push to `master`):

```
ghcr.io/rioncoreacademy/tarang2p1:v1.1
```

Workflow: `.github/workflows/publish-image.yml`

## What Is Inside the Image

- Ubuntu 22.04
- XFCE4 desktop
- TightVNC server
- noVNC + websockify (browser-based VNC)
- Python 3 + pip
- xfce4-terminal, mousepad editor

## File Locations

| Path | Purpose |
|------|---------|
| `/workspaces/projects/.build.enc/` | **WORK** — encrypted `.enc` files, git repo, read-only files |
| `/workspaces/projects/build/` | **BUILD** — decrypted read-only `.v` copies (tmpfs, RAM only) |

## Working with Files

**Open a lab file (two ways):**
```bash
gvim /workspaces/projects/.build.enc/counter.v.enc   # direct path to .enc
gvim counter.v      # wrapper auto-redirects to counter.v.enc
```

**Only `.enc` files are allowed.** If you try to create a plain `.v` file:
- `vi test.v` → wrapper silently opens `test.v.enc` instead
- `touch test.v` → sweep detects and encrypts it within seconds
- `cp file.v ./` → sweep encrypts it and locks in place

**Decrypted `.v` files in `/workspaces/projects/build/` are read-only** — for simulation tools only. Edit via gvim on the `.enc` file.

## SSH Key Setup

Clipboard is blocked inside the container. Use `curl` to add your SSH key to GitHub directly:

```bash
ssh-keygen -t ed25519 -C "your_email@example.com"

curl -X POST \
  -H "Authorization: token GITHUB_PERSONAL_TOKEN" \
  -H "Content-Type: application/json" \
  https://api.github.com/user/keys \
  -d "{\"title\":\"Tarang2_dp1\",\"key\":\"$(cat ~/.ssh/id_ed25519.pub)\"}"
```

Get a token at: **github.com → Settings → Developer settings → Personal access tokens → New token** (scope: `write:public_key`)

## Troubleshooting

**Desktop not loading:**
```bash
export USER=ubuntu && bash /workspaces/tarang2p1/.devcontainer/single-user/start.sh
```

**Check if VNC is running:**
```bash
ps aux | grep -E "vnc|websockify" | grep -v grep
```

**Check websockify log:**
```bash
cat /tmp/novnc.log
```
