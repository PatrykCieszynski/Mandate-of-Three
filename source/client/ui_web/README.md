# Production CEF TypeScript

Edit `ts/` for production browser logic. `web/` contains the committed static
JavaScript emitted by TypeScript, alongside the unchanged HTML/CSS and local
asset staging. CEF still loads `web/inventory/game.html` with the existing CSP
and relative `.js` module imports. No npm package or TypeScript runtime is loaded
by CEF; no dev server, bundler, framework, remote script or eval is involved.

Use Node 20.19+ (CI uses Node 24). From this directory, install the pinned
**development** dependencies once:

```powershell
npm ci --ignore-scripts --no-audit --no-fund
npm run format:check
npm run build
npm run check
```

Use `npm run format` for deterministic formatting of Core UI and the production
screen/composition modules, then rebuild their committed JS. The formatter is a
pinned development dependency; generated template source is excluded. CI checks
formatting alongside strict TypeScript and generated asset ownership.

## Browser development without Godot

From this directory, run:

```powershell
npm run dev
```

Open `http://127.0.0.1:4173/` in Edge/Chrome or the Codex browser. From the
repository root the equivalent is `npm --prefix source/client/ui_web run dev`.
For another port, use `npm run dev -- --port 4174`. Ctrl+C stops the host and
compiler watches. No Godot, Playwright, account or game server is needed.

The command builds production and preview TypeScript, then watches both. Window
HTML templates also regenerate on edits. Reload the page after compilation;
there is no hot-reload framework or additional runtime dependency. CSS is served
directly from the production tree. `web/` JS remains generated and committed as
usual; `.dev/` is ignored development output.

The preview iframe loads the real `web/inventory/game.html`, Core UI and screen
composition, including the unchanged production CSP and skin adapter. A local
response injects a separate development IPC stand-in before the game entrypoint;
the production HTML, bridge, store and views contain no preview flag or fallback.
The server binds only to loopback and serves the runtime and explicit preview
files. Development source/output is excluded from game export presets.

The panel supplies populated/empty fixtures, Inventory/Equipment/Storage visibility, the seven supported
UI scales, Wallet updates, an Escape shortcut and outgoing command inspection.
Commands reject by default. Accept mode returns successful command results and
hides closed windows, but does not implement item placement, equip eligibility,
economy or other server rules. Item state changes come from fixtures. This host
is for browser UI work, not a simulated authoritative game backend.

Storage is a browser-preview screen in `ts/screens/storage/`, composed from the
same UiWindow, tabs, item grid/slots and tooltip as the other screens. Its typed
screen model has two 15-column × 9-row pages (270 cells total), independently of
Inventory's native 5×9×4 validation. It reuses the production application's
manager and item resolver, so activation, dragging, scale and viewport changes
apply across all three windows. On narrow viewports, the Storage frame is capped
to the logical viewport width and its grid scrolls horizontally at unchanged
40px cell size. Page I and II fixtures include tall items and boundary stacks.
Item clicks are logged as `storage.item_action` preview actions only. There is
no Storage native domain, command, transfer, persistence or server implementation.
The native production entrypoint still mounts only Inventory and Equipment.

Use Godot for native CEF embedding/transparency, IPC transport, focus/input
handoff, settings-derived scale and live snapshots/server command effects. The
browser host can exercise the presentation behavior of those contracts only.
The optional browser runner also tests the real preview host without injecting
an alternate test bridge; default headless smoke remains unchanged.

From the repository root:

```powershell
& ./tools/build-web-ui.ps1
& ./tests/run-web-ui.ps1
& ./tests/run-smoke.ps1
```

The scripts accept `-NodeExecutable` to choose an installed Node. The client
launcher builds before Godot import/start; direct Godot loads and exports also
work from a clean checkout using the committed JS. After changing `ts/`, rebuild
and commit both source and emitted JS. CI rebuilds and rejects changes to the
committed runtime tree. Emitted declarations are ignored and serve only to type
check tests importing the generated `.js`; they are excluded from game exports.

`test/*.mts` are the production Web UI contract tests and fixtures. The test
runner compiles production first, compiles tests into ignored `.tests/*.mjs`,
and runs those modules against the emitted `web/*.js`. jsdom supplies a real DOM
fixture with explicit layout/pointer-capture substitutes for headless contracts.
It does not assert screenshots or exact DOM layouts. The optional browser runner
also compiles the typed milestone test and serves the actual static runtime:

```powershell
& ./tests/run-core-ui-browser.ps1 -PlaywrightModule <installed-module-directory> -BrowserExecutable <installed-browser-executable>
```

Playwright's package is a type-only test dependency; this command uses the
explicitly supplied installed module/browser and downloads no browser.

`protocol/contracts.ts` describes IPC, domain snapshots and commands. Window
geometry lives in `core/window/window-types.ts`, assets in `core/assets/types.ts`
and `skin-keys.ts`, and item presentation in `game-ui/item-types.ts`. `protocol.ts` validates native input:
`JSON.parse` is assigned to `unknown`, then passed to `decodeAndValidate`.
Command results keep their existing exact-field checks. Domain fields consumed by the views
are validated before the store clones/replaces them; a malformed update retains that
domain's last known valid state, so unrelated updates can still render. Full
snapshots are validated atomically before replacing disposable state. The store
and `readDomainSnapshot` use the same domain validation, including numeric bounds.

Inventory dimensions are positive integers capped at the current native 5×9×4
contract; item heights are 1–3 and coordinates/footprints fit the supplied grid.
Item count cannot exceed grid capacity. Revisions are nonnegative safe integers;
quantities are positive safe integers. Wallet balance is an integer from zero to
native `WalletStoreSqlite.MAX_YANG` (9,000,000,000,000,000). Attack is finite,
nonnegative and at most `Number.MAX_SAFE_INTEGER`; fractions remain valid because
native equipment stats are floats. HUD scale uses the seven existing native
values (0.8, 0.9, 1, 1.1, 1.25, 1.4, 1.5). Viewport dimensions are integers from
zero (hidden/minimized host) to a presentation safety ceiling of 16,384 pixels.
Extra domain fields remain allowed; player data remains opaque until a screen
consumes a concrete player contract. These guards do not decide ownership,
equipment eligibility, transactions or other server gameplay rules.

The optional legacy asset manifest is generated local asset data, loaded as
`unknown` and checked by its adapter. Skin/item icon paths stay in that adapter
and the existing resolvers. The Core UI refactor preserves the production visual
design, persistence policy and command wire format; see [ownership and Storage
acceptance](../../../docs/core-ui.md).

The build first embeds `ts/core/window/templates/ui-window.html` in an ignored,
generated TypeScript module. The emitted template JS is committed with the
other runtime modules. `npm run build`, `npm run check` and the PowerShell build
all regenerate it; CEF does not fetch templates or require Node at runtime.

Storage preview now supports drag/drop and click-to-carry within/between the two
containers and between pages. Ctrl + left click transfers the whole item/stack
to the first fitting free cell, scanning destination pages then rows/columns.
Occupied, out-of-bounds, full and stale-revision moves leave fixtures intact.
Escape/right click, close, resize, scale or fixture reset cancels carrying.
The dev interaction controller reuses production footprint/snapping and item
icon presentation; it is mounted only by the preview host, with Storage open.
The native Inventory interaction and IPC contract remain unchanged. These
fixture operations are independent of the accept-command checkbox.
