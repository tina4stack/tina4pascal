# Tina4Pascal MCP service

A small [tina4-python](https://tina4.com) app that exposes the whole
Tina4Pascal native dev loop over the **Model Context Protocol**, so an agent
or the IDE can build, deploy, debug, screenshot and **drive** apps on
macOS / iOS / Android — the same commands `tools/tina4pascal` runs by hand.

Every tool shells out to `../tina4pascal`, so the MCP surface and the CLI never
drift. The server speaks plain Streamable-HTTP MCP — it is not tied to any one
agent or editor. Any MCP client (Claude Code, Cursor, Windsurf, VS Code, Codex,
Zed, Continue, or your own) connects to the same URL.

## Quick start

Three steps, then jump to [Connect your dev tool](#connect-your-dev-tool).

### 1. Install the two prerequisites

You need the `tina4` CLI (starts the server) and `uv` (installs its one Python
dep). Everything else is already in this repo.

| OS | Get `tina4` | Get `uv` |
|---|---|---|
| **macOS / Linux** | `curl -fsSL https://tina4.com/install.sh \| sh` | `curl -LsSf https://astral.sh/uv/install.sh \| sh` (macOS: `brew install uv`) |
| **Windows** | `irm https://tina4.com/install.ps1 \| iex` | `powershell -c "irm https://astral.sh/uv/install.ps1 \| iex"` |

The `tina4.com` one-liner is the easiest install (it also runs `tina4 setup` to
fetch the toolchain). Prefer a package manager? `cargo install tina4` and prebuilt
release binaries from [tina4.com](https://tina4.com) work too.

### 2. Start the server

```bash
cd tools/mcp
uv sync                        # installs tina4-python (its only dependency)
TINA4_DEBUG=true tina4 serve   # serves MCP on http://localhost:7146/tina4pascal
```

Leave it running. It prints the endpoint on boot. (Always `tina4 serve` — never
`python app.py`; the Rust CLI wires up the MCP transport.)

Change host/port in `tools/mcp/.env` (`TINA4_HOST`, `TINA4_PORT`) if `7146` is
taken — then use the new URL everywhere below.

## Tools

| Tool | What it does |
|---|---|
| `tina4_doctor` | report the toolchain (FPC/Android/iOS/Java) |
| `tina4_init` `{name, directory?}` | scaffold a NEW project (full layout) + build it for the host — no window; returns the project path |
| `tina4_build` `{target, project?}` | build a project's app (with `project`) or cross-compile the engine (`android`/`ios`/`macos`/`win64`/`linux`/`all`) |
| `tina4_run` `{project, target?}` | build a project + launch its native app detached; returns the exe path |
| `tina4_render` `{project, target?, overlay?}` | build + render one frame HEADLESS to an image (optional layout overlay) → returns the image path to read |
| `tina4_dom` `{project}` | dump the running DOM tree as JSON (headless) |
| `tina4_boxes` `{project}` | dump the layout-box tree (geometry + box model) as JSON |
| `tina4_inspect` `{project, x, y}` | inspect the element at (x,y): tag, box, computed styles ("inspect element") |
| `tina4_script` `{project, script}` | replay a UI script headlessly (click/type/scroll + `snap` between steps) — deterministic automation; snaps are images you can read |
| `tina4_where` `{project, target?}` | print the built artifact's path |
| `tina4_test` | run the DOM/CSS unit suites |
| `tina4_compliance` `{glob?}` | run the W3C reftest suite |
| `tina4_deploy` `{target}` | build + install/open + launch |
| `tina4_launch` `{target}` | re-foreground the installed app, no rebuild |
| `tina4_debug` `{project?, breakpoint?, target?}` | with `project`: native gdb debug (build w/ symbols, run headless, Pascal backtrace on crash); else on-device build→launch→screenshot→tail log |
| `tina4_release` `{keystore,alias,store_pass,key_pass}` | build a release-signed Android APK |
| `tina4_screenshot` `{target}` | grab the app screen → returns the PNG path |
| `tina4_tap` `{target,x,y}` | click/tap at screen coords |
| `tina4_swipe` `{target,x1,y1,x2,y2,ms?}` | scroll / drag |
| `tina4_text` `{target,value}` | type into the focused field |
| `tina4_logs` `{target,lines?}` | on-device log (android app-pid/crash · ios CoreDevice syslog) |

Live input (`tap`/`swipe`/`text`) is fully wired for **Android** today; on
iOS/macOS `deploy`/`debug`/`screenshot` work now and live input arrives with a
WebDriverAgent / in-app automation bridge (see `docs/ROADMAP.md`).

## Connect your dev tool

### 3. Point your client at it

One endpoint, every client: **`http://localhost:7146/tina4pascal`** (Streamable
HTTP, with legacy SSE). There are two ways in:

- **Native HTTP** — modern clients take the URL directly. Preferred.
- **stdio bridge** — older / stdio-only clients wrap it with
  [`mcp-remote`](https://www.npmjs.com/package/mcp-remote):
  `npx -y mcp-remote http://localhost:7146/tina4pascal` (needs Node ≥ 18). This
  works for **any** MCP client, so it is the universal fallback.

Pick your tool and paste the matching block. Restart the client afterwards.

<details><summary><b>Claude Code</b> (CLI)</summary>

```bash
claude mcp add --transport http tina4pascal http://localhost:7146/tina4pascal
```
</details>

<details><summary><b>Cursor</b> — <code>~/.cursor/mcp.json</code> (or <code>.cursor/mcp.json</code> in the project)</summary>

```json
{
  "mcpServers": {
    "tina4pascal": { "url": "http://localhost:7146/tina4pascal" }
  }
}
```
</details>

<details><summary><b>Windsurf</b> — <code>~/.codeium/windsurf/mcp_config.json</code></summary>

```json
{
  "mcpServers": {
    "tina4pascal": { "serverUrl": "http://localhost:7146/tina4pascal" }
  }
}
```
</details>

<details><summary><b>VS Code</b> (Copilot agent mode) — <code>.vscode/mcp.json</code></summary>

```json
{
  "servers": {
    "tina4pascal": { "type": "http", "url": "http://localhost:7146/tina4pascal" }
  }
}
```
</details>

<details><summary><b>Zed</b> — <code>settings.json</code> → <code>context_servers</code></summary>

```json
{
  "context_servers": {
    "tina4pascal": {
      "command": { "path": "npx", "args": ["-y", "mcp-remote", "http://localhost:7146/tina4pascal"] }
    }
  }
}
```
</details>

<details><summary><b>Claude Desktop / Codex / any stdio-only client</b> — <code>command</code> + <code>args</code></summary>

Claude Desktop: `claude_desktop_config.json`
(macOS `~/Library/Application Support/Claude/`, Windows `%APPDATA%\Claude\`).
Codex: `~/.codex/config.toml` under `[mcp_servers.tina4pascal]`. Same idea —
launch the `mcp-remote` bridge as the server command:

```json
{
  "mcpServers": {
    "tina4pascal": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://localhost:7146/tina4pascal"]
    }
  }
}
```
</details>

Once connected, ask your agent to run `tina4_doctor` — it should report the
toolchain, confirming the tools are live.

## Troubleshooting

- **Client shows no tools / can't connect** — is `tina4 serve` still running in
  `tools/mcp`? Open `http://localhost:7146/tina4pascal` in a browser; a JSON/SSE
  response means the server is up. The client must be restarted after editing its
  config.
- **`tina4: command not found`** — the CLI isn't on PATH. Reinstall (step 1) or
  point at the binary's full path.
- **`mcp-remote` errors** — needs Node ≥ 18 (`node -v`); the server must be
  running first. Prefer a native-HTTP client block if your tool has one.
- **Port `7146` in use** — change `TINA4_PORT` in `tools/mcp/.env`, restart the
  server, and update the URL in every client block.
- **A tool errors** — the MCP just shells out to `tools/tina4pascal`; run the
  same command by hand there to see the raw output. Start with `tina4pascal
  doctor` for a toolchain report.
