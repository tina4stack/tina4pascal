# Task: iOS device tooling maintenance

**Outcome:** Safely land and verify the iOS tunnel, signing-team, screenshot, and MCP follow-up without including local app or build artifacts.

## Scope
- [x] Review pending iOS CLI and MCP changes
- [x] Keep generated watchOS artifacts ignored
- [x] Verify shell, Python, and project test gates
- [ ] Commit and push the verified changes

## Parity
| Surface | macOS/iOS | Android | Windows/Linux |
|---|---|---|---|
| Device tooling | ✅ CLI/MCP verified | — | — |

## Tests (real)
- [x] POSIX shell syntax and iOS CLI contract checks
- [x] MCP route compilation
- [x] Tina4Pascal test suite — 20/20 passed on macOS

## Bugs
- [x] Generated watch static library was no longer ignored after the ignore-rule rewrite.
- [x] iOS log collection did not receive the cached Remote Service Discovery address.

## Commits
- 7444757  fix(ios): reuse native device tunnel

## Status: Complete
