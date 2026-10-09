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
npm run build
npm run check
```

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

`contracts.ts` describes the existing IPC payloads, domain/view models, commands,
geometry, skin keys and icon identifiers. `protocol.ts` validates native input:
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
and the existing resolvers. The TypeScript migration changes no visual design,
window/component architecture, persistence policy or command wire format.
