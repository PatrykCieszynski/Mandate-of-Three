# Historical Web UI foundation validation — 2026-10-08

Evidence from the retired native fixture and copied-client setup. These are not
current setup instructions or CI checks. Use [Web UI](../web-ui.md) and
[CEF integration](../cef-addon-integration.md) for current behavior.

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
its blank composition remains a foundation fixture; the Inventory screen has
its own client composition and gameplay integration tests.

These final browser runs execute assertions during the runner's sampling window,
so their CPU/RAM samples are **not idle performance measurements**. No fresh idle
benchmark is claimed. Keep the original spike's rough +205/+222 MiB baseline as
historical evidence only. Vulkan's injected mouse release-to-Godot state response
was about 18.5 ms in this run; that is not physical input-to-photon latency.
Captured UI/3D output remained around 60 FPS in the short fixture.

Recommendation: **ADOPT WITH CAVEATS**. The transport, application boundary and
state lifecycle are ready for a first small real screen on the validated Vulkan
path, which is now the official CEF target. Compatibility/software drag failures
remain documented best-effort findings and are outside the supported scope.
The existing client's renderer has not been changed by this work. Do not call
the overall deployment production ready until the remaining release gates are
resolved.

Remaining gates: non-debug packaging, physical input/IME/DPI/alt-tab, helper crash
behavior, long soak and a target-device memory/renderer budget. Linux/macOS and server/client release exports remain untested. The first
inventory integration is separately documented.
