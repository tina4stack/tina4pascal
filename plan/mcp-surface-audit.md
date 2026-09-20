# Task: MCP surface audit

**Outcome:** Make the Tina4Pascal MCP server accurately expose the safe build, visual-verification, and iOS tooling flows available in the CLI.

## Scope
- [x] Compare MCP tools with the current CLI surface
- [x] Verify the iOS tunnel route and test route through the live MCP module
- [x] Add missing safe PDF and standalone-snapshot routes
- [x] Verify routes, documentation, and the full Pascal suite
- [ ] Commit and push the audit

## Parity
| Surface | CLI | MCP | Status |
|---|---|---|---|
| iOS tunnel | ✅ | ✅ | Verified |
| Project PDF | ✅ | ✅ | Verified |
| Static snapshot | ✅ | ✅ | Verified |
| Rendering/compliance | ✅ | ✅ | Verified |

## Tests (real)
- [x] MCP module import and route calls
- [x] PDF export from the calculator project
- [x] Static snapshot from a repository HTML fixture
- [x] Tina4Pascal test suite — 20/20 passed on macOS

## Bugs
- [x] MCP screenshot could report a pre-existing image even when the CLI call failed.

## Commits
- 5b3399f  feat(mcp): expose PDF and snapshot tooling

## Status: Complete
