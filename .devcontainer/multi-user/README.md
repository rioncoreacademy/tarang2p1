# Tarang2_dp1 — Multi-User Server Setup

One Codespace acts as a shared server. Students log in via GitHub OAuth and each get their own isolated VNC desktop running as a Docker container.

## Architecture

```
Students (browser)
       |
       v
FastAPI portal (port 80) — GitHub OAuth login
       |
       v
Docker containers (ports 6081–6085)
  cc-student1 → noVNC desktop on 6081
  cc-student2 → noVNC desktop on 6082
  cc-student3 → noVNC desktop on 6083
```

- FastAPI runs directly inside the devcontainer (not as a Docker container) so Codespaces can forward port 80
- Each student container is spawned dynamically using the Docker socket (docker-outside-of-docker)
- Sessions are stored in-memory — students must re-login if the server restarts
- Student work is persisted in named Docker volumes (`tarang2p1-{username}`)

## Files

| File | Purpose |
|------|---------|
| `devcontainer.json` | Codespaces config — base image, features, port forwarding, secrets |
| `init.sh` | Runs on Codespace creation — writes `.env`, builds `ubuntu-novnc:latest` image |

## Setup Steps (One-Time)

### 1. Create a GitHub OAuth App

Go to GitHub → Settings → Developer settings → OAuth Apps → **New OAuth App**

| Field | Value |
|-------|-------|
| Application name | Tarang2_dp1 |
| Homepage URL | Your Codespace portal URL |
| Authorization callback URL | `https://{codespace-name}-80.app.github.dev/callback` |

Save the **Client ID** and **Client Secret**.

> **Note:** The callback URL changes every time you create a new Codespace. Update it in the OAuth App settings each time.

### 2. Add Codespaces Secrets

Go to repo → Settings → Secrets and variables → Codespaces → **New secret**

| Secret name | Value |
|-------------|-------|
| `GH_CLIENT_ID` | OAuth App Client ID |
| `GH_CLIENT_SECRET` | OAuth App Client Secret |
| `VNC_PASSWORD` | VNC password for student desktops (e.g. `novnc`) |
| `CHIPCRAFT_KEY` | Encryption key for lab files (optional) |
| `TEMPLATE_REPO` | GitHub repo to clone per student e.g. `rioncoreacademy/lab-template` (optional) |

> **Important:** Secret names must NOT start with `GITHUB_` — that prefix is reserved by GitHub. Use `GH_` prefix instead.

### 3. Create the Codespace

Go to repo → **Code → Codespaces → Create codespace on main**

Select **"Tarang2_dp1 — Multi-User Server"** config.

### 4. Build the Student Desktop Image

After the Codespace starts, run in the terminal:

```bash
cd /workspaces/tarang2p1 && docker build -t ubuntu-novnc:latest .
```

This builds the `ubuntu-novnc:latest` image that students' containers use.

### 5. Start the API Server

```bash
cd /workspaces/tarang2p1/api && nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 80 > /tmp/api.log 2>&1 &
```

### 6. Make Port 80 Public

Codespace → **Ports tab** → right-click port 80 → **Port Visibility → Public**

### 7. Update OAuth App Callback URL

Copy the Codespace URL for port 80 (e.g. `https://laughing-parakeet-xxx-80.app.github.dev`) and update the GitHub OAuth App **Authorization callback URL** to:

```
https://{codespace-name}-80.app.github.dev/callback
```

## Student Instructions

1. Go to the portal URL (e.g. `https://laughing-parakeet-xxx-80.app.github.dev/`)
2. Click **Login with GitHub**
3. Authorize the app
4. Click **Launch Tarang2_dp1**
5. XFCE4 desktop opens in a new tab

## API Routes

| Route | Description |
|-------|-------------|
| `GET /` | Portal home — login page or student dashboard |
| `GET /login` | Redirects to GitHub OAuth |
| `GET /callback` | GitHub OAuth callback — creates session |
| `GET /launch` | Spawns student Docker container and redirects to noVNC |
| `GET /ping` | Keep-alive — prevents session timeout |
| `GET /logout` | Destroys session and stops student container |

## Port Configuration

Currently configured for 5 simultaneous students (ports 6081–6085).

To increase capacity, add more ports to `devcontainer.json`:

```json
"forwardPorts": [80, 6081, 6082, ..., 6110]
```

And update `init.sh`:
```bash
PORT_END=6110
```

Practical limit: ~30 students on a 4-core/8GB Codespace machine (~200MB RAM per container).

## Monitoring

**Watch API logs:**
```bash
tail -f /tmp/api.log
```

**List running student containers:**
```bash
docker ps | grep cc-
```

**Remove all student containers:**
```bash
docker rm -f $(docker ps -aq --filter "name=cc-")
```

## Known Limitations

- Codespace URL changes every time a new Codespace is created → must update OAuth callback URL
- Sessions are lost when the Codespace suspends (after 30 min idle)
- Free GitHub plan: 120 compute hours/month
- For permanent class use, deploy on a VPS with a fixed domain instead

## Troubleshooting

**"At capacity" error:**
```bash
docker rm -f $(docker ps -aq --filter "name=cc-")
```

**"GitHub login failed" on callback:**
- Check the OAuth App callback URL matches the current Codespace URL
- Make sure `GH_CLIENT_SECRET` secret is set correctly

**Port 80 not reachable:**
- Make port 80 Public in the Ports tab
- Check uvicorn is running: `ps aux | grep uvicorn`

**ubuntu-novnc image not found:**
```bash
cd /workspaces/tarang2p1 && docker build -t ubuntu-novnc:latest .
```
