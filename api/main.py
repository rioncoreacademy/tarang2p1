#!/usr/bin/env python3
import os
import secrets
import threading
import time

import docker
import httpx
from fastapi import Cookie, FastAPI, Request
from fastapi.responses import HTMLResponse, RedirectResponse

app = FastAPI()

GITHUB_CLIENT_ID     = os.environ.get("GITHUB_CLIENT_ID", "")
GITHUB_CLIENT_SECRET = os.environ.get("GITHUB_CLIENT_SECRET", "")
TEMPLATE_REPO        = os.environ.get("TEMPLATE_REPO", "")
NOVNC_IMAGE          = os.environ.get("NOVNC_IMAGE", "ubuntu-novnc:latest")
VNC_PASSWORD         = os.environ.get("VNC_PASSWORD", "novnc")
CHIPCRAFT_KEY        = os.environ.get("CHIPCRAFT_KEY", "")
SHARED_PATH          = os.environ.get("SHARED_PATH", "/data/workspace/project")
SESSION_TTL          = int(os.environ.get("SESSION_TTL", "14400"))  # 4 hours
PORT_START           = int(os.environ.get("PORT_START", "6081"))
PORT_END             = int(os.environ.get("PORT_END", "6180"))       # 100 slots
CODESPACE_NAME       = os.environ.get("CODESPACE_NAME", "")         # set automatically by Codespaces

_sessions: dict = {}
_lock = threading.Lock()


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


threading.Thread(target=_cleanup_loop, daemon=True).start()


# ── container helpers ───────────────────────────────────────────────────────

def _launch_container(github_user: str, port: int, session_token: str) -> str:
    dc = docker.from_env()
    vol = f"chipcraft-{github_user}"
    try:
        dc.volumes.get(vol)
    except docker.errors.NotFound:
        dc.volumes.create(vol)

    c = dc.containers.run(
        NOVNC_IMAGE,
        name=f"cc-{session_token[:12]}",
        detach=True,
        ports={"6080/tcp": ("0.0.0.0", port)},
        environment={"VNC_PASSWORD": VNC_PASSWORD, "CHIPCRAFT_KEY": CHIPCRAFT_KEY},
        volumes={
            SHARED_PATH: {"bind": "/home/ubuntu/shared", "mode": "ro"},
            vol:         {"bind": "/home/ubuntu/work",   "mode": "rw"},
        },
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
        container.exec_run(
            ["bash", "-c", f"rm -rf ~/lab && git clone {repo_url} ~/lab"],
            user="ubuntu",
        )
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
        f"?client_id={GITHUB_CLIENT_ID}&scope=repo&state={secrets.token_urlsafe(8)}"
    )
    return RedirectResponse(url)


@app.get("/callback")
async def callback(code: str):
    async with httpx.AsyncClient() as client:
        r = await client.post(
            "https://github.com/login/oauth/access_token",
            json={
                "client_id": GITHUB_CLIENT_ID,
                "client_secret": GITHUB_CLIENT_SECRET,
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
        return f"https://{CODESPACE_NAME}-{port}.preview.app.github.dev/vnc.html"
    host = request.headers.get("host", "localhost").split(":")[0]
    return f"http://{host}:{port}/vnc.html"


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
