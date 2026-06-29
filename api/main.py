#!/usr/bin/env python3
import os
import secrets
import threading
import time

import docker
import httpx
from fastapi import Cookie, FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel

app = FastAPI()

GH_CLIENT_ID     = os.environ.get("GH_CLIENT_ID", "")
GH_CLIENT_SECRET = os.environ.get("GH_CLIENT_SECRET", "")
TEMPLATE_REPO        = os.environ.get("TEMPLATE_REPO", "")
NOVNC_IMAGE          = os.environ.get("NOVNC_IMAGE", "ubuntu-novnc:latest")
VNC_PASSWORD         = os.environ.get("VNC_PASSWORD", "novnc")
CHIPCRAFT_KEY        = os.environ.get("CHIPCRAFT_KEY", "")
SHARED_PATH          = os.environ.get("SHARED_PATH", "/data/workspace/project")
SESSION_TTL          = int(os.environ.get("SESSION_TTL", "14400"))  # 4 hours
PORT_START           = int(os.environ.get("PORT_START", "6081"))
PORT_END             = int(os.environ.get("PORT_END", "6180"))       # 100 slots
CODESPACE_NAME       = os.environ.get("CODESPACE_NAME", "")         # set automatically by Codespaces
# Docker network that the API is on — student containers join it to reach /lab-key
COMPOSE_NETWORK      = os.environ.get("COMPOSE_NETWORK", "nvr_default")
# Bootstrap token is valid for this many seconds (consumed on first use)
BOOTSTRAP_TTL        = int(os.environ.get("BOOTSTRAP_TTL", "30"))

_sessions: dict = {}
_lock = threading.Lock()

# One-time bootstrap tokens: token → expiry timestamp
_bootstrap_tokens: dict = {}
_tokens_lock = threading.Lock()


# ── background cleanup ──────────────────────────────────────────────────────

def _destroy_container(container_id: str):
    try:
        docker.from_env().containers.get(container_id).remove(force=True)
    except Exception as e:
        print(f"destroy error: {e}", flush=True)


def _cleanup_loop():
    while True:
        time.sleep(300)
        now = time.time()
        expired = []
        with _lock:
            for token, sess in list(_sessions.items()):
                if now - sess.get("last_seen", sess["created_at"]) > SESSION_TTL:
                    expired.append((token, sess.get("container_id")))
            for token, _ in expired:
                _sessions.pop(token, None)
        for _, cid in expired:
            if cid:
                print(f"expiring container {cid[:12]}", flush=True)
                threading.Thread(target=_destroy_container, args=(cid,), daemon=True).start()

        # Purge stale bootstrap tokens that were never consumed
        with _tokens_lock:
            stale = [t for t, exp in _bootstrap_tokens.items() if now > exp]
            for t in stale:
                del _bootstrap_tokens[t]


threading.Thread(target=_cleanup_loop, daemon=True).start()


# ── container helpers ───────────────────────────────────────────────────────

def _launch_container(github_user: str, port: int, session_token: str) -> str:
    dc = docker.from_env()
    vol = f"chipcraft-{github_user}"
    try:
        dc.volumes.get(vol)
    except docker.errors.NotFound:
        dc.volumes.create(vol)

    # One-time token the container exchanges for the real key over the internal network.
    # The key itself never enters the student container's environment.
    boot_token = secrets.token_urlsafe(32)
    with _tokens_lock:
        _bootstrap_tokens[boot_token] = time.time() + BOOTSTRAP_TTL

    c = dc.containers.run(
        NOVNC_IMAGE,
        name=f"cc-{session_token[:12]}",
        detach=True,
        ports={"6080/tcp": ("0.0.0.0", port)},
        environment={
            "VNC_PASSWORD":     VNC_PASSWORD,
            "BOOTSTRAP_TOKEN":  boot_token,
            "API_INTERNAL_URL": "http://api:8000",
            "WORK_DIR":         "/home/ubuntu/lab",
            "LAB_DIR":          "/home/ubuntu/lab/.build",
            # Used to watermark decrypted files so leaks can be traced
            "GITHUB_USER":      github_user,
        },
        volumes={
            SHARED_PATH: {"bind": "/home/ubuntu/shared", "mode": "ro"},
            vol:         {"bind": "/home/ubuntu/work",   "mode": "rw"},
        },
        # Build scratch space, nested inside ~/lab rather than a sibling
        # folder. RAM only (tmpfs) — plaintext from `make` never touches disk.
        # 2g, not 100m: Verilator C++ builds (precompiled headers, object
        # files for a full RTL project) need much more than a single
        # iverilog compile of one file ever did. tmpfs is a ceiling, not a
        # reservation — only consumes RAM as data is actually written.
        tmpfs={"/home/ubuntu/lab/.build": "size=2g,uid=1000,gid=1000,mode=0700"},
        # Join the compose network so the container can reach http://api:8000
        network=COMPOSE_NETWORK,
        # Needed so entrypoint.sh can apply egress iptables rules
        cap_add=["NET_ADMIN"],
    )
    return c.id


def _clone_repo(container_id: str, github_user: str, github_token: str, template_repo: str):
    repo_name = template_repo.split("/")[-1]
    repo_url = f"https://{github_token}@github.com/{github_user}/{repo_name}.git"
    dc = docker.from_env()

    with httpx.Client() as client:
        client.post(
            f"https://api.github.com/repos/{template_repo}/forks",
            headers={"Authorization": f"token {github_token}"},
        )

    time.sleep(10)  # wait for VNC server inside container to initialize
    try:
        container = dc.containers.get(container_id)
        # Clone into a temp dir then merge into ~/lab — cloning directly
        # into ~/lab (or rm -rf'ing it first) fails because the .build
        # tmpfs mount (declared at container creation) already exists
        # there; rm -rf can't remove an active mount point either, so it
        # would survive the wipe and still block a direct clone right after.
        clone_cmd = (
            "TMPCLONE=$(mktemp -d) && "
            f"git clone {repo_url} \"$TMPCLONE\" && "
            "mkdir -p ~/lab && shopt -s dotglob && "
            "mv \"$TMPCLONE\"/* ~/lab/ && "
            "rmdir \"$TMPCLONE\""
        )
        container.exec_run(["bash", "-c", clone_cmd], user="ubuntu")
    except Exception as e:
        print(f"clone error: {e}", flush=True)


# ── pages ───────────────────────────────────────────────────────────────────

def _login_page() -> str:
    return """<!DOCTYPE html>
<html>
<head>
  <title>ChipCraft — Learn with R. Babu</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    *{margin:0;padding:0;box-sizing:border-box}
    body{background:#0d1117;color:#e6edf3;font-family:-apple-system,sans-serif;
         display:flex;align-items:center;justify-content:center;min-height:100vh}
    .card{background:#161b22;border:1px solid #30363d;border-radius:12px;
          padding:48px 40px;text-align:center;width:360px}
    .logo{font-size:48px;margin-bottom:16px}
    h1{font-size:22px;margin-bottom:8px}
    p{color:#8b949e;font-size:14px;margin-bottom:32px}
    .btn{display:inline-flex;align-items:center;gap:10px;background:#238636;
         color:#fff;padding:12px 24px;border-radius:8px;text-decoration:none;
         font-size:15px;font-weight:500}
    .btn:hover{background:#2ea043}
  </style>
</head>
<body>
  <div class="card">
    <div class="logo">&#128187;</div>
    <h1>ChipCraft</h1>
    <p>Learn Digital Design &amp; VLSI with R. Babu</p>
    <a href="/login" class="btn">
      <svg width="20" height="20" viewBox="0 0 16 16" fill="white">
        <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38
                 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13
                 -.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66
                 .07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15
                 -.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0
                 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56
                 .82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07
                 -.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/>
      </svg>
      Login with GitHub
    </a>
  </div>
</body>
</html>"""


def _portal_page(github_user: str) -> str:
    return f"""<!DOCTYPE html>
<html>
<head>
  <title>ChipCraft — Learn with R. Babu</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    *{{margin:0;padding:0;box-sizing:border-box}}
    body{{background:#0d1117;color:#e6edf3;font-family:-apple-system,sans-serif;
         display:flex;align-items:center;justify-content:center;min-height:100vh}}
    .card{{background:#161b22;border:1px solid #30363d;border-radius:12px;
          padding:48px 40px;text-align:center;width:400px}}
    .logo{{font-size:40px;margin-bottom:16px}}
    h1{{font-size:22px;margin-bottom:6px}}
    .user{{color:#58a6ff;font-size:14px;margin-bottom:28px}}
    .tools{{display:flex;gap:8px;justify-content:center;flex-wrap:wrap;margin-bottom:32px}}
    .tag{{background:#21262d;border:1px solid #30363d;border-radius:20px;
          padding:4px 12px;font-size:12px;color:#8b949e}}
    .btn{{display:block;background:#238636;color:#fff;padding:14px;border-radius:8px;
          text-decoration:none;font-size:16px;font-weight:600;margin-bottom:12px}}
    .btn:hover{{background:#2ea043}}
    .btn-out{{background:transparent;border:1px solid #30363d;color:#8b949e;
              font-size:13px;padding:9px}}
    .btn-out:hover{{background:#21262d;color:#e6edf3}}
  </style>
</head>
<body>
  <div class="card">
    <div class="logo">&#128187;</div>
    <h1>Welcome to ChipCraft</h1>
    <div class="user">@{github_user} &middot; Learn with R. Babu</div>
    <div class="tools">
      <span class="tag">Verilator</span>
      <span class="tag">SDCC</span>
      <span class="tag">GTKWave</span>
      <span class="tag">gvim</span>
      <span class="tag">XFCE4 Desktop</span>
    </div>
    <a href="/launch" class="btn">&#128640; Launch ChipCraft Lab</a>
    <a href="/logout" class="btn btn-out">Logout</a>
  </div>
</body>
</html>"""


def _busy_page() -> str:
    return """<!DOCTYPE html>
<html>
<head>
  <title>ChipCraft — No Desktops Available</title>
  <style>
    body{background:#0d1117;color:#e6edf3;font-family:-apple-system,sans-serif;
         display:flex;align-items:center;justify-content:center;min-height:100vh}
    .card{background:#161b22;border:1px solid #30363d;border-radius:12px;
          padding:48px 40px;text-align:center;width:360px}
    h1{font-size:20px;margin-bottom:12px;color:#f85149}
    p{color:#8b949e;font-size:14px;margin-bottom:24px}
    a{color:#58a6ff;text-decoration:none}
  </style>
</head>
<body>
  <div class="card">
    <h1>Lab is at capacity</h1>
    <p>All lab slots are in use. Please wait a few minutes and try again.</p>
    <a href="/">&#8592; Back to portal</a>
  </div>
</body>
</html>"""


# ── routes ──────────────────────────────────────────────────────────────────

@app.get("/")
async def home(session: str = Cookie(default=None)):
    if session and session in _sessions:
        return HTMLResponse(_portal_page(_sessions[session]["github_user"]))
    return HTMLResponse(_login_page())


@app.get("/login")
def login():
    url = (
        f"https://github.com/login/oauth/authorize"
        f"?client_id={GH_CLIENT_ID}&scope=repo&state={secrets.token_urlsafe(8)}"
    )
    return RedirectResponse(url)


@app.get("/callback")
async def callback(code: str):
    async with httpx.AsyncClient() as client:
        r = await client.post(
            "https://github.com/login/oauth/access_token",
            json={
                "client_id": GH_CLIENT_ID,
                "client_secret": GH_CLIENT_SECRET,
                "code": code,
            },
            headers={"Accept": "application/json"},
        )
        token_data = r.json()

    github_token = token_data.get("access_token")
    if not github_token:
        return HTMLResponse("<h1>GitHub login failed. <a href='/'>Try again</a></h1>")

    async with httpx.AsyncClient() as client:
        r = await client.get(
            "https://api.github.com/user",
            headers={"Authorization": f"token {github_token}"},
        )
        user_data = r.json()

    session_token = secrets.token_urlsafe(24)
    now = time.time()
    with _lock:
        _sessions[session_token] = {
            "github_user":  user_data["login"],
            "github_token": github_token,
            "container_id": None,
            "port":         None,
            "created_at":   now,
            "last_seen":    now,
        }

    resp = RedirectResponse("/")
    resp.set_cookie("session", session_token, httponly=True, samesite="lax")
    return resp


def _desktop_url(port: int, request: Request) -> str:
    if CODESPACE_NAME:
        return f"https://{CODESPACE_NAME}-{port}.app.github.dev/"
    host = request.headers.get("host", "localhost").split(":")[0]
    return f"http://{host}:{port}/"


@app.get("/launch")
async def launch(request: Request, session: str = Cookie(default=None)):
    if not session:
        return RedirectResponse("/")

    github_user = github_token = None

    with _lock:
        sess = _sessions.get(session)
        if not sess:
            return RedirectResponse("/")

        sess["last_seen"] = time.time()

        # Already has a running container — redirect back to it
        if sess.get("container_id") and sess.get("port"):
            return RedirectResponse(_desktop_url(sess["port"], request))

        # Find a free port and reserve it atomically
        used = {s["port"] for s in _sessions.values() if s.get("port")}
        port = next((p for p in range(PORT_START, PORT_END + 1) if p not in used), None)
        if port is None:
            return HTMLResponse(_busy_page(), status_code=503)

        sess["port"] = port
        github_user  = sess["github_user"]
        github_token = sess["github_token"]

    # Create container outside the lock (Docker call is slow)
    try:
        container_id = _launch_container(github_user, port, session)
    except Exception as e:
        print(f"launch error: {e}", flush=True)
        with _lock:
            if session in _sessions:
                _sessions[session]["port"] = None
        return HTMLResponse(_busy_page(), status_code=503)

    with _lock:
        if session in _sessions:
            _sessions[session]["container_id"] = container_id

    if TEMPLATE_REPO:
        threading.Thread(
            target=_clone_repo,
            args=(container_id, github_user, github_token, TEMPLATE_REPO),
            daemon=True,
        ).start()

    return RedirectResponse(_desktop_url(port, request))


class _KeyRequest(BaseModel):
    token: str


@app.post("/lab-key")
async def lab_key(request: Request, body: _KeyRequest):
    """Internal-only endpoint: exchanges a one-time bootstrap token for the lab key.
    Reachable only from within the Docker network (not from students' browsers)."""
    client_ip = request.client.host

    # Accept only Docker-internal addresses; reject anything that came from outside.
    _internal = ("172.", "10.", "192.168.", "127.")
    if not any(client_ip.startswith(p) for p in _internal):
        raise HTTPException(status_code=403, detail="forbidden")

    now = time.time()
    with _tokens_lock:
        expiry = _bootstrap_tokens.pop(body.token, None)   # single-use: consumed here

    if expiry is None or now > expiry:
        raise HTTPException(status_code=401, detail="invalid or expired token")

    if not CHIPCRAFT_KEY:
        raise HTTPException(status_code=503, detail="key not configured on server")

    print(f"lab-key issued to {client_ip}", flush=True)
    return {"key": CHIPCRAFT_KEY}


@app.get("/ping")
async def ping(session: str = Cookie(default=None)):
    """Keep-alive endpoint — prevents session from expiring while lab is open."""
    if session and session in _sessions:
        with _lock:
            if session in _sessions:
                _sessions[session]["last_seen"] = time.time()
        return {"ok": True}
    return {"ok": False}


@app.get("/logout")
def logout(session: str = Cookie(default=None)):
    container_id = None
    with _lock:
        sess = _sessions.pop(session, None)
        if sess:
            container_id = sess.get("container_id")

    if container_id:
        threading.Thread(target=_destroy_container, args=(container_id,), daemon=True).start()

    resp = RedirectResponse("/")
    resp.delete_cookie("session")
    return resp


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
