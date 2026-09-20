# Task: Mobile scrolling and rendering optimisation

**Outcome:** Keep Android and iOS scrolling responsive by coalescing redraws to
vsync, retaining the existing viewport cull, and using UIKit's retained layer
for truly local animation repaints.

## Scope
- [x] Route iOS animation-only invalidations through the existing regional paint path
- [x] Coalesce Android drag/fling redraw requests to the next display frame
- [x] Preserve full repaints for scrolling, layout, and input changes
- [x] Build both native shells and run the portable regression suite
- [ ] Commit and push the completed work

## Parity
| Change | Android | iOS | Shared output |
|---|---|---|---|
| Scroll redraw | Vsync-coalesced full frame | Full frame | Unchanged |
| Animation redraw | Full frame | Region paint + retained layer | Unchanged |
| Off-screen boxes | Existing viewport cull | Existing viewport cull | Unchanged |

## Tests (real)
- [x] Android native libraries and debug APK
- [x] iOS static library and unsigned arm64 device app
- [x] Tina4Pascal portable suite — 20/20 passed

## Bugs
- [x] iOS requested a small animation dirty rect but always called the full-frame painter.

## Commits
- [ ] Pending

## Status: In progress
