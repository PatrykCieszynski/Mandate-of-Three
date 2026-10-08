# CEF screen-space UI spike

Tested 2026-10-08. Recommendation: **ADOPT WITH CAVEATS** as a candidate for trusted,
local desktop UI. This is evidence for a subsequent production integration gate,
not approval to migrate Mandate's existing UI now.

## Isolation and installation

Production `project.godot`, addons, autoloads, gameplay, servers and inventory are
unchanged. The adapter and mock are source files; the runnable project, native
plugin, profile, downloads, logs and screenshots live under ignored `.godot/`.
No CEF binary is installed in the main project's addon path. Removing this topic
and its ignored cache reverts the spike without touching production UI.

Plugin: [dsh0416/godot-cef v2.0.0](https://github.com/dsh0416/godot-cef/releases/tag/v2.0.0),
released 2026-10-03, source commit `f8027f610c60a9740ceb8a263f144962ff6d5f62`.
Manifest minimum Godot 4.6; tested Godot 4.7.2 stable, API 4.6 Rust binding.
The pinned CEF crate is 154.3.0. Windows x64 store artifact SHA256:
`6d58235aa47b654a0a9410dfd40e9d7cb43ffe13d034d9f24fdb44cc2cea1b33`.
The store archive is 686,188,009 bytes and also contains other desktop platforms;
the setup extracts only Windows x64 binaries and common addon files.

Run from the repository root in PowerShell, with Python 3.11+:

```powershell
python tools/cef_ui_spike/setup.py
& ./tests/run-cef-ui.ps1 -Mode Compatibility -Interactive
& ./tests/run-cef-ui.ps1 -Mode Vulkan -Interactive
```

Setup downloads the official pinned artifact once and verifies its checksum on
every invocation. Installation requires internet; the running UI does not. Re-run
setup after changing source: the isolated project uses copies, not a production
addon or junction. The runner expects the existing engine in `.godot/` and imports
the standalone project before launching it. Interactive mode has native Godot
buttons for open/close, reload, recreate, resize and quit; it is bounded to ten
minutes and writes local logs.

The native view is a transparent `CefTexture` covering the viewport, anchored to
all edges. Native toolbar and a rotating 3D cube provide integration references.
HTML/CSS/JS, system fonts and all assets are bundled locally. No framework, CDN,
package manager, web server, authentication or gameplay connection is required.

## Adapter and bridge

`source/client/ui_web/web_ui_host.gd` alone uses CEF classes, properties, methods
and signals. It dynamically instantiates `CefTexture`, avoiding a hard class
reference in scripts imported by headless Godot. `web_ui_bridge.gd` owns transport
readiness and the explicit command whitelist. `ui_command_router.gd` owns only the
mock authoritative inventory. No CEF API escapes into gameplay code.

Verified against the pinned native implementation and official
[methods](https://godotcef.org/api/methods),
[properties](https://godotcef.org/api/properties) and
[signals](https://godotcef.org/api/signals):

- Browser properties: `url`, `background_color`, `enable_accelerated_osr`,
  `popup_policy=0` (block), `permission_policy=0` (deny).
- Web to Godot: `window.sendIpcMessage(JSON.stringify(envelope))` ->
  `ipc_message(message: String)`.
- Godot to web: `send_ipc_message(json)` ->
  `window.ipcMessage.addListener(callback)`.
- Lifecycle: `reload()`, `load_started(url)`, `load_finished(url,status)`.
  `console_message` has four arguments: level, message, source, line.
- `eval()` is used by the trusted test fixture to drive assertions, never by a
  web command. No method-name dispatch, NodePath, filesystem or system operations
  are exposed by the bridge.

Commands must be exact `{type,payload}` objects, at most 4096 characters. The
allowed domain command is:

```json
{"type":"inventory.move_item","payload":{"id":"potion","x":1,"y":1,"revision":1}}
```

The other lifecycle command is `UI_READY` with an empty payload. Test-only
`spike.report` diagnostics are disabled by default and enabled by the fixture.
Malformed JSON, extra fields, non-integer/non-finite coordinates, stale revisions,
unknown items and unknown command names cannot invoke Godot methods.

The web listener is installed before sending `UI_READY`. Godot then sends
`state.snapshot`; subsequent `state.update` messages include the full small mock
state and an optional command result. Godot updates a mock tick every second.
Reload/removal resets transport readiness; the next `UI_READY` rehydrates the
current Godot state. There is no second persistent web state to reconcile.

## Inventory result

6 x 7 grid, item width one, heights 1/2/3, no rotation. Pointer capture supports
moving an item; the proposed cells show green/red previews. The UI sends even an
invalid proposal to exercise authoritative rejection. Godot checks shape,
revision, bounds and overlap. An optimistic placement is replaced by the full
accepted/rejected snapshot. Preview images were inspected visually: item heights,
green free-cell preview and red overlap preview render correctly over the 3D scene.
This is a local client-side Godot mock, not the game's server inventory or DB path.

## Repeatable checks and observations

```powershell
python tools/cef_ui_spike/setup.py
& ./.godot/Godot_v4.7.2-stable_win64_console.exe --headless --path .godot/cef-spike/baseline --script res://tests/cef_ui/router.gd
& ./tests/run-cef-ui.ps1 -Mode Baseline -Measure
& ./tests/run-cef-ui.ps1 -Mode Compatibility -Measure
& ./tests/run-cef-ui.ps1 -Mode BaselineVulkan -Measure
& ./tests/run-cef-ui.ps1 -Mode Vulkan -Measure
```

| Check | Result on Windows x64 |
| --- | --- |
| Startup, initial snapshot, live tick updates | PASS on Compatibility and Vulkan |
| Ten hide/show cycles | PASS; same browser and authoritative state retained |
| Reload | PASS; new UI_READY and full snapshot |
| Browser remove/free and recreation | PASS; new UI_READY retains item revision |
| Valid drag/drop | Passed on both renderers; one repeat failed mouse delivery after resize (see below) |
| Invalid bounds/overlap | PASS; Godot rejects, snapshot restores placement |
| Keyboard text, Tab, hide/release focus | PASS through injected engine events |
| Resize | PASS; 1280x900 window gives 1280x884 Chromium content with canvas stretch |
| Transparency | PASS by CSS inspection and captured visual output |
| CSP remote fetch | PASS; connect-src none rejects fetch before network access |
| Unexpected about:blank navigation | PASS; bridge reset and browser removed |
| Native popup/permission policy | Both explicitly set to block/deny |
| Graceful quit | PASS; owned process descendants exit |
| Orphan CEF subprocesses | Final runs: zero live descendants; an earlier two-second check reported five helpers (see below) |

Mouse events use `Viewport.push_input(event,true)` in logical viewport coordinates;
keyboard uses `Input.parse_input_event`. These exercise real CefTexture routing,
Chromium DOM events and IPC, but do not prove physical Windows input, IME,
clipboard, gamepad, DPI scaling or alt-tab behavior. Native computer-use tooling
was unavailable in this environment. The fixture explicitly requests window
focus with Godot's `Window.grab_focus()` before input checks; an earlier unfocused
run failed injected input. Foreground/background policy belongs in future client
integration, not in the mock bridge. A first incorrect mouse coordinate injection
also failed under viewport stretching; using local viewport coordinates resolved
that test-fixture error.

Browser hide retains its runtime. Freeing a node closes that browser, while CEF's
process-wide runtime remains available for recreation until application shutdown.
There is no public close method used here. The runner tracks only descendants of
its owned launch, records survivors at two seconds and checks live CIM process IDs for up to
ten seconds after normal quit, and cleans them if a test fails.
This is a short lifecycle test, not a long-duration leak/soak study. One short run reported five helpers at
the initial two-second Get-Process check; the runner cleaned those owned helpers.
The final runner distinguishes early survivors from live PIDs after the longer
observation window. This early result is not discarded as proof of clean shutdown.

Main-project headless import, all 882 source/resource loads, isolated router
checks and the existing two-client spike3d network test passed. The existing Yang
server/two-client regression also passed during this work. Main-project headless
exit still reports ObjectDB/resource-in-use warnings from its existing autoload
lifecycle; CEF is not loaded there. No server export/package was produced.

## Performance sanity check

Windows 10 Home 10.0.19045; Ryzen 5 5600X (12 logical processors), RTX 4070,
NVIDIA driver 610.88. Same rotating-cube fixture, capped at 60 FPS. The runner
samples the owned process tree around seconds 10-18 before input assertions.
Idle means no user interaction; the 3D cube still renders and Godot publishes
one UI update per second. Samples include console wrapper and console host, not
just native Godot. Summed working sets may double-count shared pages; private
bytes are committed process memory, not dedicated GPU memory.

| Renderer | Baseline private MiB | With CEF private MiB | Approx. increase | Baseline / CEF CPU, one-core % | Processes baseline / CEF |
| --- | ---: | ---: | ---: | ---: | ---: |
| Compatibility software | 153 | 358 | +205 MiB | 8.45 / 11.01 | 3 / 8 |
| Vulkan Mobile accelerated | 614 | 836 | +222 MiB | 5.64 / 10.73 | 3 / 8 |

Summed working sets were approximately 176 -> 458 MiB (Compatibility) and
490 -> 772 MiB (Vulkan). Additional total-machine CPU was roughly 0.2-0.4
percentage points on this 12-thread CPU. Counts include five additional CEF helpers.
Final Compatibility and Vulkan runs passed all assertions and recorded no live
helper PIDs at either the two-second or final shutdown survey. Logs and metrics
are `.godot/cef-spike/{compatibility,vulkan}.measure.{out.log,err.log,metrics.json}`.
Prior runs varied in memory/CPU; earlier failed input runs remain documented below.

CPU is percent of one logical core (100% = one fully occupied core); divide by
12 for approximate total-machine percent. These are short single-run means,
subject to driver warm-up, background tasks and allocator variation, not a
benchmark or a guaranteed budget. The script uses floating-point CPU-time deltas;
an initial integer-overload bug reported zero CPU and those samples were discarded.

Compatibility logs unsupported accelerated OSR and supplies `ImageTexture`:
software rendering is functional. Vulkan Mobile logs accelerated mode and supplies
`Texture2DRD`; the rendered UI, transparency, resize and input checks also pass.
That supports GPU operation on this specific device, not every driver/backend.
The plugin installs Vulkan device/queue hooks; see its
[Vulkan support notes](https://godotcef.org/api/vulkan-support). Main renderer
settings remain untouched. No D3D12, Forward+, other GPU or GPU-memory measurement.

Engine-injected mouse release to Godot command result took roughly 1-2 ms in the
observed runs. The fixture and captures show 60 FPS with no obvious rendering
stall. This measures an IPC/validation response, not physical input-to-photon
latency; visual latency and sustained drag smoothness need a manual pass.

## Security, known limitations and platform notes

- Trusted bundled content only. CSP denies connect/frame/object/form access;
  application opens only one fixed res URL. JS prevents link navigation/popups,
  and native popup/permission policies are restrictive.
- Upstream v2.0.0 `on_before_browse` has no public synchronous navigation veto.
  Our load_started guard fires after navigation has begun. It closes unexpected
  pages and detaches commands, but is not a network firewall. The about:blank
  test proves the guard, not pre-request blocking of arbitrary remote URLs.
- CEF sandbox is disabled upstream (`no_sandbox=true` / no-sandbox subprocess
  flag). No insecure web-security/certificate switches were added by this spike.
  Do not admit untrusted HTML, downloaded UI or mods into this trust boundary.
- Built-in res:// and user:// scheme handlers are broader than this one UI
  directory. There is no custom filesystem bridge, but this is not a filesystem
  isolation boundary. Standalone project/profile limit the available data.
- Debug Godot enables CEF DevTools on localhost:9229. There is no tested public
  off switch in this build; the configured port is clamped above zero. Upstream
  gates it on debug/editor status. Non-debug export behavior still needs testing.
- A full-screen transparent TextureRect still hit-tests as a rectangle: transparent
  pixels do not automatically pass clicks to the 3D game. Screen-space input
  ownership must be designed before production integration. Native toolbar works
  because it is above the browser layer.
- No plugin crash was observed. Final live-PID shutdown checks found no helpers,
  with the earlier early-survivor caveat above. Two repeated Compatibility
  runs failed some or all drag mouse assertions after resize while has_focus was true and
  keyboard assertions still passed; no inventory mutation occurred. Other focused
  runs passed the same sequence. This remains an intermittent integration/input
  finding, not a proven physical-input plugin defect and not something hidden
  with native input hacks. Manual reproduction is a production adoption gate. The final fixture waits up to one second for an IPC
  command result instead of assuming a fixed 150 ms delay is sufficient; final
  Compatibility checks passed. This does not explain every earlier missing pointer
  event or replace physical input verification. Compatibility's software fallback is an expected
  limitation, and short successful tests do not establish long-term stability.
- Only Windows x64 was installed/tested. Release contains Linux x64 and macOS
  universal artifacts; store package omits Windows/Linux ARM64. Other operating
  systems, exports, packaging, multi-monitor/DPI, IME and long soak remain untested.

## Decision

**ADOPT WITH CAVEATS** for the next bounded client experiment. The real API,
transparent rendering, UI_READY recovery, authoritative mock validation and
short lifecycle tests are good enough to continue evaluating this as Mandate's
screen-space UI candidate. A plain local DOM fits the inventory task; no frontend
framework is justified yet.

Before selecting it as the long-term production layer, require a packaged
non-debug client test, physical input/IME/DPI/alt-tab verification, a longer
open/reload/recreation soak, a representative UI memory budget on target hardware,
and an explicit decision accepting the trusted-content/no-sandbox boundary.
Choose a deliberate renderer strategy: current Compatibility works but does not
provide accelerated OSR. Do not migrate production UI or add CEF to headless/server
builds as part of this spike.
