# Historical CEF UI spike decision

The standalone spike was retired on **2026-10-09** after the real Inventory
integration. Its mock model, diagnostic adapter, browser fixtures and measurement
runners are removed. Use the [production Web UI foundation](web-ui.md),
[Inventory](inventory-ui-prototype.md) and [prototype testing policy](testing.md).
This document retains the adoption evidence; it is not a setup guide.

Tested on 2026-10-08: godot-cef **v2.0.0**, Godot **4.7.2**, Windows x64,
Ryzen 5 5600X and RTX 4070. Recommendation: **ADOPT WITH CAVEATS**.
The later accepted renderer target is **Vulkan Mobile**; Compatibility/OpenGL
is unsupported / best-effort.

The real plugin API was inspected and exercised: transparent CefTexture,
accelerated OSR, local resource loading, IPC, load signals, reload and native
input/focus. Production CEF code remains behind WebUiHost; bridge commands are
explicitly registered. No arbitrary Godot method dispatch is exposed.

Vulkan checks passed startup, open/close, reload/recreation, resize, transparent
rendering, inventory previews/rejection, regions/focus and shutdown. Accelerated
output used Texture2DRD. Compatibility had unresolved drag/input failures after
resize. No native input forwarding or runtime-restart hacks were added.
Both measured renderer runs finished with zero owned helper survivors.

Historical rough private-memory measurements (rotating-cube fixture):

| Renderer | Without CEF | With CEF | Increase | Process count |
| --- | --- | --- | --- | --- |
| Compatibility software | 153 MiB | 358 MiB | +205 MiB | 3 → 8 |
| Vulkan Mobile accelerated | 614 MiB | 836 MiB | +222 MiB | 3 → 8 |

These are short, hardware-specific observations, not a current production UI
budget or a physical input-to-photon benchmark. Native scripted/synthetic input
must not be mistaken for manual OS mouse/keyboard, IME or DPI verification.
Remaining release gates include packaging, physical input/IME/DPI/alt-tab,
helper crashes, long soak, target-device budgets and non-Windows platforms.

Plugin download/checksum now belongs to `tools/cef_client/plugin.py`; the archive
is cached in `.godot/cef-client/cache`. The local API reference checkout moved to
`.godot/reference/godot-cef`. Duplicate standalone projects and old logs/captures
were discarded; the supported development client remains available.

The copied gameplay client was also retired on 2026-10-09: the addon is now
installed in the root project. See [current integration](cef-addon-integration.md).
