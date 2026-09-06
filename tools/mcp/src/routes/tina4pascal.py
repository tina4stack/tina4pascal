# Tina4Pascal dev tools, exposed over MCP by tina4-python.
#
# Every tool shells out to the repo's `tools/tina4pascal` CLI, so the MCP
# surface and the hand-run CLI stay one and the same. Served on /tina4pascal
# (Streamable HTTP + legacy SSE) once `tina4 serve` is running in this folder.
import os
import platform
import subprocess

from tina4_python.mcp import McpServer, mcp_tool

# repo root = four levels up from src/routes/tina4pascal.py (…/tools/mcp/src/routes)
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))

# Pick the right CLI per OS. On Windows the extensionless POSIX script is not an
# executable (WinError 193), so drive the PowerShell CLI instead; everywhere else
# use the POSIX script directly. CLI_CMD is a prefix arg list, not a single path.
if os.name == "nt":
    _PS1 = os.path.join(REPO, "tools", "tina4pascal.ps1")
    CLI_CMD = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", _PS1]
else:
    CLI_CMD = [os.path.join(REPO, "tools", "tina4pascal")]

mcp = McpServer("/tina4pascal", name="Tina4Pascal Dev Tools", version="1.0.0")

TARGETS = "android | ios | macos | win64 | linux"


def _host_target():
    """The native desktop target for the machine the server runs on."""
    s = platform.system()
    return {"Windows": "win64", "Darwin": "macos"}.get(s, "linux")


def _run(args, timeout=1800, cwd=None):
    """Run the tina4pascal CLI; return its combined output (or an error line)."""
    try:
        p = subprocess.run([*CLI_CMD, *args], cwd=(cwd or REPO), capture_output=True,
                           text=True, timeout=timeout)
        return ((p.stdout or "") + (p.stderr or "")).strip() or "(no output)"
    except subprocess.TimeoutExpired:
        return f"error: timed out after {timeout}s"
    except Exception as e:  # noqa: BLE001
        return f"error: {e}"


# Where new projects are scaffolded when the caller doesn't say. Override with
# TINA4_WORKSPACE; defaults to a `workspace/` beside the repo so projects never
# clutter the framework tree.
WORKSPACE = os.environ.get(
    "TINA4_WORKSPACE", os.path.abspath(os.path.join(REPO, "..", "tina4-workspace")))


# ── build / test ──────────────────────────────────────────────────────
@mcp_tool("tina4_doctor", description="Report the toolchain (FPC targets, "
          "Android SDK/NDK, adb, iOS, Java).", server=mcp)
def doctor():
    return _run(["doctor"])


# ── scaffold / build / run a project ──────────────────────────────────
@mcp_tool("tina4_init", description="Scaffold a NEW Tina4Pascal project (full "
          "backend-style layout: migrations/, assets/, src/{app,routes,orm,"
          "services,templates}, tina4.json) and build it for the host target. "
          "Does NOT open a window. `directory` is the parent to create it in "
          "(defaults to the server workspace). Returns the project path + log.",
          server=mcp)
def init(name: str, directory: str = ""):
    parent = directory or WORKSPACE
    os.makedirs(parent, exist_ok=True)
    log = _run(["init", name, "norun"], cwd=parent)
    return {"project": os.path.join(parent, name), "log": log}


@mcp_tool("tina4_build", description=f"Build for a target ({TARGETS} | all). "
          f"With `project` set, builds that project's native app; otherwise "
          f"cross-compiles the framework engine.", server=mcp)
def build(target: str, project: str = ""):
    return _run(["build", target], cwd=(project or REPO))


@mcp_tool("tina4_run", description="Build a project for a target and launch its "
          "native app detached (non-blocking). Returns the executable path. On a "
          "headless server the process starts but no window shows — use "
          "tina4_deploy/tina4_screenshot for on-device targets.", server=mcp)
def run(project: str, target: str = ""):
    tgt = target or _host_target()
    build_log = _run(["build", tgt], cwd=project)
    name = os.path.basename(os.path.normpath(project))
    exe = os.path.join(project, "build", tgt, name)
    if not os.path.exists(exe):
        return {"ok": False, "log": build_log}
    try:
        subprocess.Popen([exe], cwd=project,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "exe": exe, "error": str(e), "log": build_log}
    return {"ok": True, "exe": exe, "log": build_log}


@mcp_tool("tina4_where", description="Print the built app's path for a project "
          "+ target (no build). Pass the project dir; target defaults to the host.",
          server=mcp)
def where(project: str, target: str = ""):
    return _run(["where", target] if target else ["where"], cwd=project)


@mcp_tool("tina4_render", description="Build a project and render one frame "
          "HEADLESS to an image so you can SEE the desktop build (no window). "
          "Returns the image path — read it to view. Windows/macOS render fully "
          "headless; the linux target needs an X display (Xvfb/WSLg).",
          server=mcp)
def render(project: str, target: str = "", out: str = "shot",
           width: int = 900, height: int = 640, overlay: bool = False):
    tgt = target or _host_target()
    args = ["render", tgt, out, str(width), str(height)]
    if overlay:
        args.append("--overlay")
    log = _run(args, cwd=project)
    # the CLI prints the final image path as its last line
    img = (log.strip().splitlines() or [""])[-1].strip()
    return {"image": img, "log": log}


# ── debug / inspect (DevTools for Tina4) ──────────────────────────────
@mcp_tool("tina4_dom", description="Dump the running app's DOM tree as JSON "
          "(headless one-frame render). Pass the project dir.", server=mcp)
def dom(project: str):
    return _run(["dom"], cwd=project)


@mcp_tool("tina4_boxes", description="Dump the layout-box tree as JSON — every "
          "box's geometry (x/y/w/h) and box model (margin/border/padding) + "
          "display. Headless. Pass the project dir.", server=mcp)
def boxes(project: str):
    return _run(["boxes"], cwd=project)


@mcp_tool("tina4_inspect", description="Inspect the element at (x,y): tag, "
          "id/class, box geometry and key computed styles — like a browser's "
          "'inspect element'. Coords are CSS px in the viewport. Headless.",
          server=mcp)
def inspect(project: str, x: float, y: float):
    return _run(["inspect", str(x), str(y)], cwd=project)


@mcp_tool("tina4_script", description="Replay a UI script headlessly against a "
          "project: one command per line — click X Y | move X Y | drag X Y | "
          "scroll X Y DX DY | key <text> | enter | tab | backspace | esc | "
          "snap <file> | wait. Deterministic UI automation; `snap` lines write "
          "images you can read. `script` is the path to the script file.",
          server=mcp)
def script(project: str, script: str):
    return _run(["script", script], cwd=project)


@mcp_tool("tina4_test", description="Build + run all DOM/CSS unit suites.",
          server=mcp)
def test():
    return _run(["test"])


@mcp_tool("tina4_compliance", description="Run the W3C reftest suite "
          "(optional id glob).", server=mcp)
def compliance(glob: str = "*"):
    return _run(["compliance", glob])


# ── deploy / debug ────────────────────────────────────────────────────
@mcp_tool("tina4_deploy", description=f"Build + install/open + launch the app "
          f"on a target ({TARGETS}).", server=mcp)
def deploy(target: str):
    return _run(["deploy", target])


@mcp_tool("tina4_debug", description="With `project` set: NATIVE debug — build the "
          "project with DWARF symbols, run one headless frame under gdb, and return "
          "a Pascal backtrace (file:line) on any crash (or 'ran clean'). Optional "
          "`breakpoint` (function or file:line). Without `project`: the on-device "
          "build->launch->screenshot->tail-log loop for a target (android|ios|macos).",
          server=mcp)
def debug(target: str = "", project: str = "", breakpoint: str = ""):
    if project:
        args = ["debug"]
        if breakpoint:
            args += ["--break", breakpoint]
        return _run(args, cwd=project)
    return _run(["debug", target])


# ── drive the running app ─────────────────────────────────────────────
@mcp_tool("tina4_screenshot", description="Grab the app screen (android | ios "
          "| macos). Returns the saved PNG path — read it to view.", server=mcp)
def screenshot(target: str):
    out = os.path.join(REPO, "build", f"{target}.png")
    log = _run(["screenshot", target, out])
    return {"path": out, "log": log}


@mcp_tool("tina4_tap", description="Tap/click at screen coords (device px).",
          server=mcp)
def tap(target: str, x: int, y: int):
    return _run(["tap", target, str(x), str(y)])


@mcp_tool("tina4_swipe", description="Swipe / scroll / drag between two points "
          "(optional duration ms).", server=mcp)
def swipe(target: str, x1: int, y1: int, x2: int, y2: int, ms: int = 300):
    return _run(["swipe", target, str(x1), str(y1), str(x2), str(y2), str(ms)])


@mcp_tool("tina4_text", description="Type a string into the focused field.",
          server=mcp)
def text(target: str, value: str):
    return _run(["text", target, value])


@mcp_tool("tina4_logs", description="Tail the on-device log: android filters to "
          "the app's process (or surfaces a crash when it died); ios uses the "
          "CoreDevice syslog over the tunnel.", server=mcp)
def logs(target: str, lines: int = 40):
    return _run(["logs", target, str(lines)])


@mcp_tool("tina4_launch", description="Bring the already-installed app to the "
          "foreground WITHOUT rebuilding (android | ios | macos) — a fast run / "
          "re-foreground.", server=mcp)
def launch(target: str):
    return _run(["launch", target])


@mcp_tool("tina4_release", description="Build a release-SIGNED Android APK "
          "(android/tina4pascal-release.apk). Provide the keystore path/alias/"
          "passwords, or set TINA4_KEYSTORE/TINA4_KEY_ALIAS/TINA4_KS_PASS in the "
          "server env and omit them here. Create a keystore first with the CLI "
          "`tina4pascal keygen` (interactive).", server=mcp)
def release(keystore: str = "", alias: str = "", store_pass: str = "",
            key_pass: str = ""):
    env = os.environ.copy()
    if keystore:
        env["TINA4_KEYSTORE"] = keystore
    if alias:
        env["TINA4_KEY_ALIAS"] = alias
    if store_pass:
        env["TINA4_KS_PASS"] = store_pass
    if key_pass:
        env["TINA4_KEY_PASS"] = key_pass
    try:
        p = subprocess.run([*CLI_CMD, "release"], cwd=REPO, capture_output=True,
                           text=True, timeout=1800, env=env)
        return ((p.stdout or "") + (p.stderr or "")).strip() or "(no output)"
    except Exception as e:  # noqa: BLE001
        return f"error: {e}"


# ── Mount ─────────────────────────────────────────────────────────────
# Registering tools on the McpServer is not enough on its own: the HTTP
# endpoints (POST /tina4pascal streamable + SSE) are only added to the Tina4
# router when register_routes() runs. This module auto-discovers on startup, so
# mounting here is what makes the server actually reachable by an MCP client.
from tina4_python.core import router as _router  # noqa: E402

mcp.register_routes(_router)

