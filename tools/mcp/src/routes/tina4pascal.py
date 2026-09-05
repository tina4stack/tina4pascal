# Tina4Pascal dev tools, exposed over MCP by tina4-python.
#
# Every tool shells out to the repo's `tools/tina4pascal` CLI, so the MCP
# surface and the hand-run CLI stay one and the same. Served on /tina4pascal
# (Streamable HTTP + legacy SSE) once `tina4 serve` is running in this folder.
import os
import subprocess

from tina4_python.mcp import McpServer, mcp_tool

# repo root = four levels up from src/routes/tina4pascal.py (…/tools/mcp/src/routes)
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
CLI = os.path.join(REPO, "tools", "tina4pascal")

mcp = McpServer("/tina4pascal", name="Tina4Pascal Dev Tools", version="1.0.0")

TARGETS = "android | ios | macos | win64 | linux"


def _run(args, timeout=1800):
    """Run the tina4pascal CLI; return its combined output (or an error line)."""
    try:
        p = subprocess.run([CLI, *args], cwd=REPO, capture_output=True,
                           text=True, timeout=timeout)
        return ((p.stdout or "") + (p.stderr or "")).strip() or "(no output)"
    except subprocess.TimeoutExpired:
        return f"error: timed out after {timeout}s"
    except Exception as e:  # noqa: BLE001
        return f"error: {e}"


# ── build / test ──────────────────────────────────────────────────────
@mcp_tool("tina4_doctor", description="Report the toolchain (FPC targets, "
          "Android SDK/NDK, adb, iOS, Java).", server=mcp)
def doctor():
    return _run(["doctor"])


@mcp_tool("tina4_build", description=f"Cross-compile the engine for a target "
          f"({TARGETS} | all).", server=mcp)
def build(target: str):
    return _run(["build", target])


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


@mcp_tool("tina4_debug", description="Full loop: build -> launch -> screenshot "
          "-> tail log (android | ios | macos).", server=mcp)
def debug(target: str):
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


@mcp_tool("tina4_logs", description="Tail the on-device log (android logcat / "
          "ios syslog).", server=mcp)
def logs(target: str, lines: int = 40):
    return _run(["logs", target, str(lines)])
