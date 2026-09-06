# Tina4Pascal MCP service

A small [tina4-python](https://tina4.com) app that exposes the whole
Tina4Pascal native dev loop over the **Model Context Protocol**, so an agent
or the IDE can build, deploy, debug, screenshot and **drive** apps on
macOS / iOS / Android — the same commands `tools/tina4pascal` runs by hand.

Every tool shells out to `../tina4pascal`, so the MCP surface and the CLI never
drift.

## Run it

```bash
cd tools/mcp
uv sync                 # installs tina4-python (zero other deps)
TINA4_DEBUG=true tina4 serve   # serves the MCP endpoint on http://localhost:7146/tina4pascal
```

(`tina4` is the cross-language Rust CLI — `cargo install tina4` or grab a
release binary. Never `python app.py`.)

## Tools

| Tool | What it does |
|---|---|
| `tina4_doctor` | report the toolchain (FPC/Android/iOS/Java) |
| `tina4_init` `{name, directory?}` | scaffold a NEW project (full layout) + build it for the host — no window; returns the project path |
| `tina4_build` `{target, project?}` | build a project's app (with `project`) or cross-compile the engine (`android`/`ios`/`macos`/`win64`/`linux`/`all`) |
| `tina4_run` `{project, target?}` | build a project + launch its native app detached; returns the exe path |
| `tina4_test` | run the DOM/CSS unit suites |
| `tina4_compliance` `{glob?}` | run the W3C reftest suite |
| `tina4_deploy` `{target}` | build + install/open + launch |
| `tina4_launch` `{target}` | re-foreground the installed app, no rebuild |
| `tina4_debug` `{target}` | build → launch → screenshot → tail log |
| `tina4_release` `{keystore,alias,store_pass,key_pass}` | build a release-signed Android APK |
| `tina4_screenshot` `{target}` | grab the app screen → returns the PNG path |
| `tina4_tap` `{target,x,y}` | click/tap at screen coords |
| `tina4_swipe` `{target,x1,y1,x2,y2,ms?}` | scroll / drag |
| `tina4_text` `{target,value}` | type into the focused field |
| `tina4_logs` `{target,lines?}` | on-device log (android app-pid/crash · ios CoreDevice syslog) |

Live input (`tap`/`swipe`/`text`) is fully wired for **Android** today; on
iOS/macOS `deploy`/`debug`/`screenshot` work now and live input arrives with a
WebDriverAgent / in-app automation bridge (see `docs/ROADMAP.md`).

## Point a client at it

Streamable-HTTP MCP endpoint: `http://localhost:7146/tina4pascal`.
For a stdio client, front it with `mcp-remote` or your client's HTTP transport.
