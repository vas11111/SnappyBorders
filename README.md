# snappyborders

Window borders for macOS, in Swift. A reimplementation of the idea behind
[JankyBorders](https://github.com/FelixKratz/JankyBorders), rebuilt around the
two things that make the original feel heavy: the size of the buffers it asks
the window server for, and the amount of work it does per resize event.

Verified on macOS 26.6.2 (Tahoe), Apple Silicon, Swift 6.3.

## What is different

**Borders are four thin windows, not one big one.** The window server gives
every window a backing store covering its whole bounding box. A border drawn as
a single window the size of its target therefore costs `width * height * 4`
bytes at 1x and four times that at 2x - about 128 MB for one 3840x2160 window -
to paint a few pixels around the edge. Splitting the frame into a picture-frame
arrangement of four strips makes the cost track the border's *perimeter*
instead of the window's *area*.

Measured on a real session, 11 bordered windows at 2x:

| | resident |
|---|---|
| one window per border | 548 MB |
| four strips per border | 48 MB |

The same reasoning applies to resizing, because the backing store is
reallocated on every shape change - and these are small.

**The update path is built around two measured facts.**

*Creating a window-server window costs ~1-3 ms.* Nothing on the update path may
create one, so strips are created once and reshaped in place afterwards; the
drawing context is remade after a reshape, which costs ~1 us.

*Reshaping a window is what breaks a border.* Changing a window-server window's
shape replaces its backing store, and anything painted around that moment can be
clipped to the previous extent - which shows up as a border cropped to the size
it had when you started dragging, and staying that way until you resize back.
Strips are therefore allocated with 512pt of slack on their long axis, centred
on the region they need, and keep that size while it still covers the
requirement. An ordinary drag then reshapes nothing at all: measured over 452
resize events, `stripsReshaped=0`. On the rare occasion a strip must grow, the
shape change is a direct synchronous call, and the drawing context is never
recreated - it follows the window's backing store on its own, and re-making it
straight after a reshape is what bound it to the surface being replaced.

*A drawing operation on a window backing store costs a flat ~200 us regardless
of area.* Clearing 100x20 costs the same as clearing 1600x1000. What matters is
the number of operations, not their size:

| operation | cost |
|---|---|
| `SLSNewWindowWithOpaqueShapeAndContext` | 890-2800 us |
| clear *any* region of a window backing store | ~690 us idle, ~200 us busy |
| stroke *any* path into one | same |
| 4x (setShape + move) in one async transaction | ~100 us |
| `SLSMoveWindow` | 14 us |
| `SLSGetWindowBounds` | 17 us |
| `SLWindowContextCreate` | 1.2 us |

So the resize path:

- reshapes nothing in the common case, because strips carry slack;
- redraws only the strips whose own segment changed. Each strip records what it
  last painted in its own local coordinates, so widening a window - which moves
  the side strips but leaves the straight segment they draw identical - repaints
  two strips instead of four;
- gives each strip only its own segment of the ring to stroke, so the rasteriser
  is not handed the whole window's bounding box four times over;
- coalesces a runloop pass worth of resize events into one update using the
  latest bounds, so a fast drag cannot build a backlog;
- caches level, sub-level, stacking and tags, re-sending them only on change;
- gets tags, level, bounds and corner radius in one batched
  `SLSWindowQueryWindows` call rather than four round trips.

A move touches no content at all: the border's appearance does not depend on
where the window is, so a drag is one transaction moving four windows.

End-to-end, measured inside the daemon under a synthetic 120 Hz drag and resize
(`sbprobe drive`, machine under load):

| | per event |
|---|---|
| move | ~160 us |
| resize, dragging one edge | ~1.1-1.7 ms |
| resize, dragging a corner | ~3.9 ms |
| focus | ~30-680 us |

over 900 events with 10 bordered windows, at 49 MB resident.

Both are well inside a 120 Hz frame. JankyBorders' resize path additionally
wraps its work in `SLSDisableUpdate`/`SLSReenableUpdate`, which stalls the whole
window server; snappyborders never disables updates.

Drawing one window-sized border instead of four strips (`strips=off`) is worse
on both counts - 2164 us per resize and 613 MB - because the per-operation cost
is flat but the area cost is not. It is kept only for comparison.

**Synchronous window-server calls get much more expensive under load.** In
isolation the steps that resolve the front window total ~100 us. Measured inside
the daemon while a window was being dragged, the same work took 2.7 ms - the
window server is busy servicing the drag, and every synchronous round trip
queues behind it. So what matters on a hot path is not how much work a call
does, but how many round trips happen at all.

That is why the front window is no longer resolved on every focus hint.
Identifying the frontmost *process* costs 0.6 us; focus can only have moved if
that changed, or if a window we do not already consider focused was raised. That
one check took focus handling from 2723 us to 32 us per event and cut
front-window queries during a drag from 58 to 1 - and resize got faster as a
side effect, from 3369 us to 1891 us, purely because the window server was no
longer being asked redundant questions.

A focus switch also skips the clear: it changes only the colour, so the new
stroke covers exactly the pixels the old one did and `.copy` blending replaces
them outright, halving that redraw.

**No artificial delays, and far fewer focus queries.** JankyBorders sleeps 50 ms
before resolving the focused window, 10 ms after a reorder and 20 ms after a
space change. snappyborders resolves focus immediately on the front-application
change, which is the event that actually means focus moved.

Window reorders and title changes are only hints, and they fire continuously
while a window is being dragged. Resolving the front window costs a window list
plus a batched query, so those merely arm a 25 ms trailing check. That took a
drag from 126 front-window queries down to 29. Focus also survives the lock
screen, Spotlight or a menu taking front, rather than every border blinking off.

**The border sits flush outside the window.** The stroke is offset so its inner
edge lands exactly on the window edge, the way a Linux window manager reserves a
frame: `width=3` shows three points of border. A stroke centred on the edge -
what JankyBorders draws - hides half its width behind the window when stacked
below it, so half the width you ask for never appears.

**Corner radii come from the window server.** `SLSWindowIteratorGetCornerRadii`
reports each window's real radius (16, 17, 20 pt on this machine), so borders
sit concentric with the window they surround instead of guessing.

**No hand-rolled mach messages.** JankyBorders builds a raw MIG message with
hardcoded, per-OS-version message ids to read a window's sub-level.
`SLSGetWindowSubLevel` is exported and does the same thing, so that whole
version-fragile path is gone.

## Build and run

```sh
swift build -c release
./.build/release/snappyborders --selftest      # check the plumbing
./.build/release/snappyborders width=6 active_color=0xffe1e3e4 &
```

Passing options while an instance is running reconfigures it in place over a
Unix socket rather than starting a second one:

```sh
snappyborders width=8 active_color=0xff8aadf4   # retune the running instance
snappyborders --status                          # what it is tracking
snappyborders --stop
```

## Options

```
active_color=<color>      focused window          (default 0xff7aa2f7)
inactive_color=<color>    unfocused windows       (default transparent)
color=<color>             both
width=<float>             stroke width in points  (default 3.0)
padding=<float>           slack around the stroke (default 4.0)
style=round|uniform|square
                          round follows the window's own corner radius,
                          uniform pins it to 9pt, square squares it off
order=above|below         stack over or under the window (default below)
hidpi=on|off              render at the display's backing scale (default on)
glow_radius=<float>       blur radius for glow() colours (default 10.0)
blacklist="App1,App2"     never draw borders for these apps
whitelist="App1,App2"     only draw borders for these apps
enabled=on|off
strips=on|off             four thin strips vs one window-sized one (default on;
                          off is slower and ~15x heavier, kept for comparison)
window=<id>               scope the remaining options to one window
debug_fill=on             fill each strip opaque red (diagnostic)
```

Colours are `0xAARRGGBB`, `glow(0xAARRGGBB)`, or
`gradient(top_left=0x...,bottom_right=0x...)` /
`gradient(top_right=0x...,bottom_left=0x...)`.

Config file, read at startup when no options are given. If it is executable it
is run as a script; otherwise it is read as one option per line:

```
~/.config/snappyborders/snappybordersrc
~/.snappybordersrc
```

## Notes on the private API

Everything here was verified against the SkyLight export table and by probing
on the target OS rather than taken on faith. The findings that cost the most to
establish, kept because they are not documented anywhere:

- **The process must register as an app.** A plain CLI binary can create,
  position, order and draw into window-server windows - every call returns
  success and every read-back looks correct - and *nothing is ever composited*.
  `NSApplication.setActivationPolicy(.accessory)` fixes it. AppKit then owns the
  connection's event delivery, so the run loop has to be `NSApplication.run()`;
  under a bare `CFRunLoopRun` the window-server notifications stop arriving and
  borders stop following focus.
- **`SLSTransactionOrderWindow`, `SLSTransactionSetWindowLevel` and
  `SLSTransactionSetWindowSubLevel` do not take effect.** They return success,
  and `SLSWindowIsOrderedIn` then reports the window as ordered in, but it never
  reaches the screen. Level and stacking use the direct calls, which are cheap.
- **`SLSTransactionSetWindowShape` ignores the origin it is passed.** It applies
  the new size only, so a move has to ride along in the same transaction or a
  window resized from its top-left corner leaves its border behind.
- **`SLSWindowIteratorGetCornerRadii` returns a borrowed array**, per "Get"
  naming. Releasing it - which JankyBorders does - is an over-release that
  corrupts the process minutes later, far from the call.
- **Window creation option bit 2 (`0x4`) requests the backing store.** Clearing
  it gives a window that allocates nothing; such a window can have a `CAContext`
  layer tree bound to it via `SLSBindSurface`, the binding reads back correctly,
  and it composites nothing at all.
- **`SLSBindSurface`'s fourth argument is the `CAContext` id**, not an `x`
  offset as the usual six-argument prototype suggests. Passing `0` there
  silently *unbinds*.
- **There is a floor on how attached a border can look.** `SLSSetWindowParent`
  returns success but does not propagate movement, and movement groups are
  rejected across connections, so the window server will not move a border
  together with a window another process owns. Every border has to be driven
  from notifications, which arrive after the window has already moved - so a
  third-party border on macOS is always at least a frame behind, in a way a
  Linux window manager drawing the frame itself never is. What is controllable
  is how much time we add on top of that, which is what the numbers above are.
- **Window movement groups are not usable here.** `SLSSetWindowMovementGroup`
  is rejected across connections (`kCGErrorIllegalArgument`), and
  `SLSSetWindowParent` returns success but does not propagate movement. There is
  no way to have the window server move a border together with a window it does
  not own, so borders have to be driven from events - which is why the work per
  event is what matters.

A layer-tree implementation would be better still: `CALayer` borders are a
compositor primitive, so a resize would cost a bounds change (10 us, measured)
and no backing store at all. That path is implemented and verified up to the
point of binding, and does not render; the notes above record how far it got.

**Geometry is sent asynchronously, so it has to be re-checked.** Shape, move and
stacking changes are committed asynchronously - that is what keeps them off the
critical path - but a change can be dropped or land out of order while the
window server is saturated mid-drag. The update path tracks the geometry it
*asked* for, so a lost update is never noticed and the border stays broken after
the gesture ends. Once a resize or drag settles (120 ms of quiet), the border
resyncs: every strip is reshaped and repainted and stacking re-asserted, from
the window's actual bounds rather than from what we believe. Once per gesture,
so none of it lands on the hot path.

Stacking is re-asserted for the same reason. Ordering a strip relative to its
target places it there at that moment only; when the target is later raised, its
strips stay put and the border ends up partly behind whatever moved between
them, which reads as missing edges.

## Diagnostics

`sbprobe` keeps the checks that established the above:

```sh
./.build/release/sbprobe bench    # cost of every call on the update path
./.build/release/sbprobe zorder   # where a window lands in the stack, per level
./.build/release/sbprobe txn      # which SLSTransaction* calls really take effect
./.build/release/sbprobe show     # put a window on screen, to eyeball it
./.build/release/sbprobe churn    # drive a running instance with window events
./.build/release/sbprobe drive    # 120 Hz drag + resize load, to time the daemon
./.build/release/sbprobe front    # break down front-window resolution
```

Because screen capture needs a permission this tool does not have, it can also
render its own output offscreen - through the real update path, into bitmaps
instead of window-server windows - so the strip decomposition can be inspected
and regressions caught without looking at the screen:

```sh
snappyborders --render-test  --w=900 --h=600 --radius=16 --out=/tmp/b.png
snappyborders --render-sequence --sizes=900x600,800x600,700x600 --out=/tmp/s.png
snappyborders --render-diff  --sizes=900x600,800x600,700x600
```

`--render-diff` replays a resize sequence and compares the result against a
border built straight at the final size. Any difference is stale strip content.

`snappyborders --status` reports per-event timings and, for each border, whether
it is in sync with its window and how much backing store it saves.
`snappyborders --rescan` re-adopts every window on the visible spaces.
`SB_TRACE=1` makes the daemon log every event and border operation.

## Licence and attribution

GPL-3.0. See [LICENSE](LICENSE).

This is an independent Swift implementation, but it is not a clean-room one:
[JankyBorders](https://github.com/FelixKratz/JankyBorders) by Felix Kratz is
GPL-3.0, and its source was read closely while building this. The window-server
event ids, the window tag bits, the "is this a real window" predicate and
several drawing constants are derived from it, and the notes throughout this
README describe where its approach was kept and where it was changed. Licensing
this the same way is the honest reflection of that.

The private-API behaviour documented here was established by probing the system
directly; those findings are facts about macOS rather than anything taken from
upstream.
