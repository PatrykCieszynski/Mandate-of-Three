# Web UI foundation

CEF provides DOM layout, CSS styling and browser text/pointer handling over
Godot's 3D viewport. The goal is a reusable screen-space UI boundary while Godot
retains client state and the server retains gameplay/economy authority.

The client has a small, opt-in Web UI boundary. Existing gameplay screens are
not migrated. The production source contains no mock inventory or diagnostic
commands. The runnable CEF integration remains in an isolated local project;
installing its addon in the main project is not part of this change.

The original [CEF spike](cef-ui-spike.md) is historical evidence. This document
specifies **protocol v1** and the current foundation. Its tests replace the old
unversioned bridge tests while retaining their standalone runner/cache paths.

## Architecture and application wiring

- `source/client/ui_web/web_ui_host.gd`: the only production CEF adapter. It
  creates a transparent, anchored CefTexture dynamically, sends/receives IPC,
  handles browser lifecycle, navigation and native input ownership.
- `web_ui_bridge.gd`: bounded JSON framing, protocol validation, readiness and
  explicit command whitelist. It emits `command_received(type, id, payload)`;
  it owns no inventory, progression, controller or persistent state.
- `ui_command_dispatcher.gd`: client application boundary. Explicitly registered
  validators/handlers consume commands; it retains the latest small domain
  sections for snapshots. No reflection, NodePath dispatch or game-wide bus.
- `web/protocol.js`, `bridge.js`, `store.js`: dependency-free browser framing,
  correlated requests and disposable domain state. `web/index.html` is a blank
  transparent shell, not a new gameplay screen.
- `tests/cef_ui/`: mock inventory model/controller, HTML/CSS/JS, diagnostic host
  subclass, synthetic inputs and assertions. `test.report` exists only in this
  fixture's explicit registration. Production host has no `eval()` API.

A client composition root creates host/bridge/dispatcher nodes and connects:

```gdscript
host.message_received.connect(bridge.receive)
host.navigation_started.connect(bridge.reset_transport)
bridge.outgoing.connect(host.send)
bridge.interactive_regions_received.connect(host.update_interactive_regions)
dispatcher.attach(bridge)
# Register only implemented commands, with exact payload validation.
dispatcher.register_command("inventory.move_item", validate_move, handle_move)
dispatcher.set_domain("inventory", current_inventory)
host.open()
```

Set host anchors to full rect under the client CanvasLayer. Configure a bundled
`res://...html` entry before opening; no user-provided URL is accepted. Register
handlers and seed domain sections before opening so first readiness gets complete
current state. Application controllers receive server-authoritative state and
update the dispatcher. The client copy is authoritative for web presentation;
this does not transfer gameplay/economy authority from World Server to the client.
The mock validates locally only to test the UI boundary.

A handler returns `{ok: bool, error?: String}` and independently publishes a
committed/reconciled domain state. No empty future controllers are supplied.
Only implemented commands are allowed. Actual production inventory commands
still require their existing server validation; the fixture is not that system.

## Protocol v1

Every message is a JSON object with exactly these fields:

```json
{"v":1,"type":"inventory.move_item","id":"req-123","payload":{"id":"potion","x":1,"y":1,"revision":1}}
```

`v`, `type`, and object `payload` are required. `id` is required on commands and
results, absent on lifecycle/state messages. IDs are nonempty strings up to 80
characters; browser IDs combine a per-document UUID/epoch and increasing counter.
Both sides reject malformed JSON, unknown versions, non-object payloads,
unexpected envelope fields, malformed IDs and messages over **16,384 UTF-8 bytes**.
There is no method name, node path, code string or system access command.

The bridge rejects unknown commands and commands before readiness without
executing a handler. A registered command with invalid payload receives a
correlated `{ok:false,error:"payload"}` result. Its validator checks the command's
exact fields/types; the mock requires precisely item ID, integer x/y and revision.
Bounds, overlap, stale revisions and item existence are application validation.
Unsupported framing/versions cannot be answered safely and are dropped with a
local `rejected` signal. There is no protocol negotiation or v0 compatibility.

Results acknowledge a request; they never carry replacement game state:

```json
{"v":1,"type":"command.result","id":"req-123","payload":{"ok":true}}
{"v":1,"type":"inventory.updated","payload":{"columns":6,"rows":7,"revision":2,"items":[]}}
```

The fixture publishes authoritative inventory even on placement rejection so an
optimistic drag is restored. State and result are independent; screens must not
infer equipment/wallet/inventory from the result. Unknown, duplicate or late
result IDs are ignored. Invalid result payloads cannot resolve a request. Timeout
is three seconds by default and clears pending state; it does **not** cancel a
command that Godot/server may already have processed. There are no automatic
command retries. Reconciliation comes from authoritative state/snapshot.

## Lifecycle and domain state

Listener installation precedes `ui.ready`:

```json
{"v":1,"type":"ui.ready","payload":{}}
{"v":1,"type":"ui.snapshot","payload":{"inventory":{"revision":2,"items":[]},"hud":{"ticks":15}}}
```

The dispatcher sends its complete current set of implemented domain sections on
every readiness event. Domains are `inventory`, `equipment`, `wallet`, `player`,
`hud`; absent domains are unimplemented, not fabricated empty controllers.
`inventory.updated`, `equipment.updated`, `wallet.updated`, `player.updated` and
`hud.updated` replace one complete small section. No patches or event replay.
Snapshot replaces the complete disposable JS store; domain sections must be
objects. Each real screen defines its own section schema before integration.

Reload and navigation reset bridge readiness and clear input regions/focus.
Reload/recreation creates a new document/bridge; old JS promises disappear.
Calling `ready()` in a live document explicitly rejects all its pending requests
with `reload` before requesting a full snapshot. Late results cannot restore
old state. Browser destruction/free and recreation keep dispatcher state in
Godot; hide/show keeps the same browser and layout, while releasing input.

This supports browser/document recreation, **not a proven in-process CEF crash
restart**. Upstream process-wide CEF initialization is not designed for repeated
shutdown/initialize cycles. There is no runtime restart hack. An application
restart recreates state from the normal client/server flow; dispatcher RAM is not
persistence. Native helper crash recovery and long-duration soak remain untested.

## Input ownership

HTML reports rectangles in CSS pixels, with viewport dimensions:

```json
{"v":1,"type":"ui.interactive_regions","payload":{"width":1280,"height":884,"regions":[{"id":"inventory-panel","x":870,"y":18,"w":390,"h":740}]}}
```

Region IDs must be unique, rectangles finite/nonnegative and within the reported
viewport; at most 64 rectangles, viewport at most 32768 per axis. Godot scales
these into browser-local coordinates. Host has no inventory coordinates and never
samples alpha pixels. `reportInteractiveRegions()` uses ResizeObserver, window
resize/scroll and requestAnimationFrame; dynamic screens must call its `refresh()`
after moving/hiding elements when size did not change, and `dispose()` on teardown.

In gameplay mode the host itself ignores mouse input. Before Godot GUI dispatch,
it sets the browser's `mouse_filter` to STOP inside reported interactive regions
and IGNORE outside. CefTexture's native `_gui_input` does the actual forwarding;
there is no synthetic CEF API forwarding in production. Pointer capture is latched
from an owned button press through release so dragging beyond a panel still reaches
Chromium. Wheel events never latch capture. Resize clears old rectangles until a
fresh layout report; an active drag retains capture through its release.

A click in a web region sets keyboard owner `web`; a click outside releases
browser/descendant IME-proxy focus and sets `gameplay`. Application calls
`host.set_modal(true)` to own pointer/keyboard across the viewport. Web cannot
unilaterally set modal ownership. Closing via `set_modal(false)`, hiding, reload
or destruction returns keyboard ownership to gameplay. Application can also
explicitly call `set_keyboard_owner("gameplay")` on UI close/actions.

CEF routes keys using its native focus/IME implementation. The host preserves an
already-focused editable proxy rather than grabbing browser focus on every mouse
click. Application shortcuts and gameplay controllers should use unhandled input
and/or `keyboard_owner_changed`/`keyboard_owner` to gate polling. Godot's global
`Input.is_action_pressed()` is not suppressed by GUI handling. This change does
not modify existing gameplay input to integrate a UI that is not installed there.

Place gameplay/native controls below the web layer; deliberately higher native
debug/tool controls can override hit testing. Touch, gamepad, IME, physical mouse,
DPI and alt-tab require a subsequent client/manual pass. Current foundation targets
screen-space mouse and keyboard; it does not claim a general input framework.

## Native API, security and isolation

Pinned plugin is [godot-cef v2.0.0](https://github.com/dsh0416/godot-cef/releases/tag/v2.0.0),
source `f8027f610c60a9740ceb8a263f144962ff6d5f62`, tested Godot 4.7.2 Windows x64.
The source/API were inspected, including native input_routing/focus_state and
scheme registration. Host alone uses CefTexture, popup/permission/background
properties, IPC, load signals and `reload()`. Test host alone adds `eval()` and
native diagnostic property reads. See the historical spike for archive checksum
and hardware/performance baseline.

Local HTML/CSS/JS only; CSP denies connect/frame/object/form/base access, no CDN,
web server or frontend dependencies. Native popup policy is block, permission
policy deny. Entry must be an existing bundled HTML file. Unexpected navigation
resets transport immediately and destroys the browser. **This is an after-start
guard, not a network firewall**: v2.0.0 exposes no public synchronous navigation
veto. No insecure-content, certificate-ignore or web-security-disable switch is
added. There is no download/system/filesystem bridge.

Trusted bundled UI is the security boundary. Upstream disables CEF sandbox and
registers res/user schemes with `CSP_BYPASSING`, broad Godot resource/profile
access and Access-Control-Allow-Origin `*`. Thus CSP is useful against remote
fetch (tested), but must not be presented as confinement of local resources.
Do not load untrusted/mod/downloaded HTML into this runtime. Debug builds expose
local DevTools on 9229; a non-debug packaged client remains an adoption gate.

No CEF addon, autoload or main-project setting is added. Setup extracts native
binaries only into ignored `.godot/cef-spike/project`; its headless baseline has
no addon. Host guards headless/unavailable classes and creates no browser. Server
exports must continue to exclude native CEF and UI setup. No server/client release
export is produced or claimed here.

Modules in the fixture are copied from production sources into its bundled
`web/shared` during setup. Standard URL resolution treats `tests` in `res://tests/`
as an authority; relative `../../../source` cannot traverse that authority.
Keeping shared modules on the fixture origin avoids that invalid import layout
without weakening web security or adding runtime loaders. Production modules
already reside together on `res://source/`. Setup refreshes copied directories so
removed old scripts cannot survive under obsolete UIDs in the isolated project.

## Repeatable validation

From repository root, Python 3.11+ and Node.js (no npm install):

```powershell
python tools/cef_ui_spike/setup.py
# Default: no browser or GUI window.
& ./tests/run-web-ui.ps1
# Explicit final integration check (opens the standalone fixture).
& ./tests/run-web-ui.ps1 -WithBrowser -Mode Compatibility
& ./tests/run-cef-ui.ps1 -Mode Vulkan
```

`-NodeExecutable` can point at a bundled Node binary. Re-run setup after changing
source because the fixture uses copies. Native runner retains its historical
name and records only descendants of its own launch, early survivors and live
orphan PIDs up to ten seconds after shutdown. Logs/profiles/metrics/screenshots
stay ignored. GUI evaluation and engine-injected input are test-only.

Tests cover strict protocol/whitelist/payload rejection/byte limit, request IDs,
timeout and late results, separation of results and state, full snapshot and
independent domain updates, reload pending reset, rectangle scaling and bounds,
button capture/wheel, hide/show, modal focus and headless creation guard. Real CEF
checks cover readiness, inventory rejection, reload/recreation, repeated open/close,
resize/transparency, drag previews, text/Tab, gameplay pass-through, modal close,
CSP fetch denial, navigation guard and application/helper shutdown.

## Current validation and readiness

Validated 2026-10-08 on Windows x64 / Godot 4.7.2 / RTX 4070:

| Validation | Result |
| --- | --- |
| JS protocol/request/store tests | 5 PASS |
| Godot protocol/dispatcher tests and native Control pointer fixture | PASS; baseline has no CefTexture class/addon |
| Root project headless import | PASS; existing four ObjectDB leak warnings remain |
| Items, spike3d, PvE, combat, progression, XP, Yang | All PASS, including server/two-client regressions |
| Vulkan Mobile CEF integration | PASS: all checks, green/red drag previews, rejection, reload, recreation, resize, transparency, regions, text/Tab, gameplay/modal focus, navigation guard |
| Vulkan accelerated texture | Texture2DRD; rendered capture inspected |
| Compatibility CEF integration | FAIL on four drag assertions after resize; other lifecycle, transparency, keyboard, region/modal and navigation checks PASS |
| Application/helper shutdown | Both runs: exit completed, zero survivors at two seconds and zero final orphan PIDs |

Compatibility saw a potion pointerdown but no subsequent drag preview/command;
revision stayed at 1 instead of 2. No incorrect placement was committed. This
resembles earlier intermittent software-renderer input findings in the original
spike. The cause is unresolved: this run does not prove a native plugin defect
rather than event injection/integration. The same adapter passed the complete
Vulkan sequence. No alpha hit testing, OS input helper, forced CEF forwarding or
runtime-restart workaround was added, and the failed run is not discarded.
Diagnostic pointer traces remain in the test adapter only.

The initial new fixture also failed because of a JavaScript syntax mistake and
then an invalid cross-authority relative module path. Both fixture mistakes were
corrected. Real Vulkan readiness and IPC now verify the packaged module layout.
The root production shell's modules use relative paths within the source origin;
its blank composition does not constitute a production-screen migration test.

These final browser runs execute assertions during the runner's sampling window,
so their CPU/RAM samples are **not idle performance measurements**. No fresh idle
benchmark is claimed. Keep the original spike's rough +205/+222 MiB baseline as
historical evidence only. Vulkan's injected mouse release-to-Godot state response
was about 18.5 ms in this run; that is not physical input-to-photon latency.
Captured UI/3D output remained around 60 FPS in the short fixture.

Recommendation: **ADOPT WITH CAVEATS**. The transport, application boundary and
state lifecycle are ready for a first small real screen on the validated Vulkan
path. Stable Compatibility/software drag input remains a blocker to claiming a
renderer-independent production UI foundation. The existing client's renderer
has not been changed by this work. Do not call the overall deployment production
ready until that input finding and the release gates are resolved.

Remaining gates: non-debug packaging, physical input/IME/DPI/alt-tab, helper crash
behavior, long soak and a target-device memory/renderer budget. No Linux/macOS,
server export, production client export or real inventory migration was tested.
