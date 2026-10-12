# Package C — kompozycja natywnego Core UI

Plan wykonawczy z 2026-10-12. Baza: `codex/spike-graduation`, HEAD `c6f5cbb`,
po integracji Package B i poprawkach review. Branch: `codex/spike-package-c`.
Ten dokument ustala zakres; implementacja nie jest jeszcze rozpoczęta.
Obowiązują [plan nadrzędny](spike-graduation-plan.md),
[kierunek projektu](project-direction.md), [Core UI](core-ui.md),
[Web UI](web-ui.md) i [polityka testów](testing.md).

## Cel i obecny stan

`InventoryWebController` jest obecnie kontrolerem całego klientowego UI: tworzy
CEF/bridge/dispatcher, rejestruje komendy itemów/NPC/Shop/Upgrade, koreluje RPC,
przygotowuje modele itemów i rzutuje NPC na ekran. C redukuje go do composition
root i wspólnej polityki UI, pod nazwą `CoreUiController`.

Głównym miejscem ekstrakcji jest GDScript w `source/client/ui_web/`. TypeScript
ma już zdrowy podział na `core/`, `game-ui/` i `screens/`; domeny i ich stan
pozostają w widokach. Nie przebudowujemy ich przy okazji. C nie jest kolejną
migracją całego UI ani próbą opróżnienia kontrolera do zera.

Odbiór: te same komendy, wyniki i snapshoty oraz istniejące zachowanie okien,
carry/drag, NPC approach i input ownership. Bez zmian wyglądu, gameplay authority,
transakcji, contentu ani persistence.

## Granice docelowe

| Właściciel | Odpowiedzialność |
| --- | --- |
| CoreUiController | Composition, host lifecycle, widoczność okien, skróty, skala/viewport, keyboard/pointer ownership, Alt/focus, UI failure |
| UiCommandSession | Native request IDs i oczekiwanie na wynik endpointu; timeout, cancel i odrzucanie późnych odpowiedzi |
| NpcDropTargetProjector | Ekranowe prostokąty oraz metadata konkretnych usług Upgrade z contentu |
| ItemUiAdapter | Inventory/Equipment/Storage: wspólny model itemów, walidatory komend, RPC i publikacja domen |
| NpcUiAdapter | Komendy/context NPC oraz istniejący flow interact → exact service → preselection |
| UpgradeUiAdapter | Walidacja select/execute, istniejące Upgrade RPC i snapshot |
| ShopUiAdapter | Walidacja open/buy, istniejące Shop RPC i snapshot |
| UiCommandDispatcher | Jawny rejestr handlerów, stan domen i publikacja bridge messages |
| WebUiBridge / WebUiHost | Istniejący protokół/transport oraz CEF/input routing |

Wallet pozostaje prostym `dispatcher.set_domain()`. Nie powstają osobne klasy
Equipment/Storage/Wallet ani bazowy adapter/registry/DI framework. Adaptery dostają
konkretne endpointy, dispatcher, session i kilka potrzebnych Callable; nie dostają
całego świata jako skrótu do wszystkich zależności. Endpoint jest właścicielem
aktualnego snapshotu; adapter nie utrzymuje drugiej kopii stanu domeny.

## C1 — UiCommandSession i lifecycle komendy

Jeden commit przenosi `_sequence`, `_request_epoch`, `_pending_commands` oraz
begin/wait/finish/cancel z kontrolera do jednego właściciela. Zachowujemy obecne
ID i timeout 2500 ms; timeout nie anuluje transakcji serwera i nie uruchamia retry.
Session nie zna CEF, payloadów domenowych, endpointów ani RPC. Może korzystać
z SceneTree przekazanego do oczekiwania; nie dostaje własnego gameplay ticka.

Chronione zachowanie:

- Request istnieje przed wysłaniem RPC, więc również szybka odpowiedź jest poprawna.
- Odpowiedzi mogą przyjść w dowolnej kolejności; pierwszy terminalny wynik wygrywa.
- Timeout/cancel usuwa możliwość ukończenia nowej komendy przez stary wynik.
- Reload, disconnect, failure i teardown kończą nierozstrzygnięte oczekiwania
  odpowiednio `ui_reload`, `disconnected`, `ui_unavailable`, `teardown`.
- Cancel nie zastępuje wyniku już przyjętego. Teardown nie zostawia aktywnych
  oczekiwań zależnych od usuniętego kontrolera; cleanup jest idempotentny.
- Wynik komendy i snapshot domeny są niezależne. Późniejszy autorytatywny snapshot
  może poprawnie odzwierciedlić commit, nawet gdy UI wcześniej dostało timeout.

Oddzielamy native request ID od browser command ID. Dispatcher/bridge pilnuje
transport generation: handler uruchomiony przez starą stronę nie wysyła
`command.result` do nowej strony po reloadzie, nawet jeśli JS ponownie użyje ID.
To wąski kontrakt lifecycle, nie drugi rejestr pending ani reset snapshotów.
Gating nie blokuje bieżących domain updates i pełnego snapshotu po `ui.ready`.
Weryfikujemy też, że anulowany wieloetapowy NPC flow nie wysyła kolejnego RPC.

Istniejące scenariusze `tests/web_ui_bridge.gd` i `web_bridge.test.mts` są pierwszą
regresją. Przepisujemy odwołania do prywatnych metod/maps na wynik oczekiwania.
Test wyłącznie sprawdzający pustą `_pending_commands` można zastąpić scenariuszem
late reply → nowy request. Jedyny kandydat do rozszerzenia to native coroutine
przechodząca przez reload/teardown: TS testuje swój bridge, ale nie dowodzi
izolacji native handlera między generacjami strony.

## C2 — NpcDropTargetProjector

Osobny commit przenosi dotychczasową projekcję i `_npc_upgrade_targets()`.
Projector przyjmuje aktualną kamerę, viewport i aktorów NPC przez jawne argumenty
lub wąskie Callable. Nie zna kontrolera, hosta, RPC, pending komend, NPC approach
ani server authorization. Composition wywołuje go w obecnym rytmie 100 ms
i publikuje tylko zmieniony snapshot. Nie dokładamy drugiego niezależnego ticka.

Zachowujemy viewport clipping, pomijanie aktorów za kamerą, finite checks, limit
64 targetów, ordered services i pomijanie disabled/invalid content. Target nadal
niesie `npcInstanceId`, `serviceId`, `itemDefinitionId`, `fromLevel`, `x/y/w/h`.
Jeden NPC może mieć kilka usług. Metadata nadal wynika z NPC → service →
content_ref → UpgradeDefinition; advisory target nigdy nie zastępuje walidacji
serwera przy interact/select/execute. Brak NPC/usługi/kamery nie zachowuje starego
targetu. Nie zmieniamy hitboxów, overlap ordering ani drag policy.

Przenosimy obecne content/exact-service cases z `web_ui_bridge.gd` do faktycznego
właściciela. Nie dodajemy pixel/exact geometry suite do ekstrakcji.

## C3 — adaptery domen, w trzech commitach

### C3a — ItemUiAdapter

Przenosimy wspólny `_item_ui_model()` i tooltip, rozdział bag/equipment/storage,
walidatory identity/move/equipment/storage i właściwe RPC do jednego adaptera.
Zachowujemy fractional affix display, UID/revision, icon/height/quantity, nazwy
upgrade, pozycje/page, stats i pomijanie błędnego snapshotu. Storage ma nadal
account scope i dotychczasowe 15×9×2; nie zmieniamy footprint/transfer policy.

Item identity może być wykorzystywane przez Upgrade validator, bez tworzenia
uniwersalnej biblioteki command schemas. Storage-open UX guard otrzymuje query
z composition. Close handlers i polityka `storage_open => inventory_open`
pozostają przy composition, podobnie I/B/Escape. Adapter nie steruje hostem.

Weryfikacja: istniejący smoke oraz `run-web-inventory.ps1`, w tym stale/ownership,
move/equip/unequip, exact receiving i deposit/withdrawal. Bez nowej suite per klasa.

### C3b — NpcUiAdapter + UpgradeUiAdapter

Przenosimy rejestracje/walidatory i snapshot binding NPC/Upgrade. Flow po dojściu
do NPC nadal robi interact, wybór dokładnego `service_id` i select tego itemu.
`NpcUiAdapter` używa jawnego Callable do Upgrade select; nie tworzymy cyklu
adapterów ani generycznego workflow engine. RPC failures kończą sekwencję;
unavailable service nie wybiera pierwszej innej usługi. Upgrade bez NPC-service
identity pozostaje odrzucany. World-drop to intention dla istniejącego
`begin_npc_approach`, przekazanego jako konkretna zależność.

`CoreUiController.interact_npc()` może pozostać krótkim publicznym wejściem
używanym przez world arrival. To realny caller, a nie alias dawnych prywatnych
metod dla fixtures. NPC context z wybranym Upgrade prosi composition o pokazanie
Inventory; adapter nie ustawia opened ani nie wykonuje layoutu. Zachowujemy
reakcje na disabled service, range loss i close/clear. Snapshot Upgrade i jego
obecna Attack presentation nie są rozszerzane.

Weryfikacja: smoke, `run-npc.ps1` oraz `run-upgrade.ps1`. Obecna fixture dziedzicząca
controller tylko po to, by podmienić `_npc_submit`/`_upgrade_submit`, zostaje
przepisana na jawne zależności nowego flow, z zachowaniem exact-service assertions.

### C3c — ShopUiAdapter

Przenosimy open/buy validators, exact receiving position, submit i snapshot
binding. Active Shop prosi composition o pokazanie Inventory, a zamknięcie Shop
pozostawia Inventory dostępne. Wciąż korzystamy z tego samego session lifecycle;
nie powstaje osobny pending queue Shop. Bez zmian offer/content/pricing/transaction.

Weryfikacja: smoke i `run-shop.ps1`. C3b i C3c pozostają osobnymi commitami,
żeby review nie mieszało service flow z purchase path.

## C4 — CoreUiController i zamknięcie granic

Rename pliku/class z zachowaniem `.gd.uid` i aktualizacja rzeczywistych callerów.
Wewnętrzna nazwa node `WebInventory` może pozostać: ten etap nie zmienia node paths,
RPC ani bridge protocol. Nie utrzymujemy klasy/aliasu InventoryWebController dla
fixture compatibility. Krótkie publiczne wejścia istnieją tylko dla realnych
wywołań (setup/open/scale/interact).

Composition nadal posiada skale/settings/viewport, shortcut policy, Alt/focus,
pointer capture, keyboard owner i failure fallback. Nie wyciągamy z nich kolejnego
UiLifecycleManagera. Connections do dłużej żyjących obiektów mają jawny cleanup;
na failure/exit przestajemy przyjmować nowe komendy, kończymy pending, odłączamy
własne bindings i niszczymy browser. Sprawdzamy to bez tworzenia CEF headless.

Rozszerzamy istniejący architecture guard o konkretne usunięte zależności:
session bez world/domain/CEF/persistence, projector bez commands/host/approach,
adaptery bez whole-world/CEF/persistence oraz brak domain RPC submit i modelowania
itemów w composition. Odwołania do typów adapterów w setup są oczywiście legalne.
Guard pilnuje połączeń, nie liczby klas/metod ani długości kontrolera.

Aktualizujemy core-ui/web-ui i plan nadrzędny, opisując właścicieli oraz realne
wyniki sprawdzeń. Brak native playtestu nie może zostać zapisany jako PASS.

## Weryfikacja i zasada testów

Po każdym spójnym commicie: import/parse GDScript przy zmianie klas, `git diff
--check` i default smoke. Smoke zawiera już headless bridge oraz Web UI suites;
nie uruchamiamy dodatkowo identycznych checks bez powodu. Network suite wybieramy
zgodnie z etapem, wszystkie wspólne porty sekwencyjnie. Na zamknięcie C nie
powtarzamy całego combatu/ACTION/FEEL, jeśli nie dotykamy ich zachowania.

Na milestone uruchamiamy istniejące `run-core-ui-browser.ps1` i
`run-shop-browser.ps1` z dostępnym browser/module, bez pobierania narzędzi.
Obejmują rzeczywisty production DOM i gesty. Natywny Godot/CEF pass osobno:
I/B/Escape i cancel carry, item drag między oknami, NPC drop → approach → exact
service, Upgrade/Shop, Alt/focus loss, camera pointer capture, reload i UI failure.
Browser/headless PASS nie jest dowodem native input routing/Vulkan.

Existing behavior tests > nowe integration cases > implementation unit tests.
Nowy przypadek wymaga wskazania konkretnej luki. Nie zachowujemy prywatnych pól,
aliasów ani starej odpowiedzialności wyłącznie dla testów; scenariusze kontraktu
pozostają. Nie robimy line/path coverage dla adapterów/session/projectora,
prywatnych call-order assertions ani nowej suite dla każdej ekstrakcji.

## Poza Package C i integracja

Bez visual pass, frontend frameworka, protocol manifestu, content registry,
generic stat delta, multi-material Upgrade, nowego TargetManagera ani World split.
Ground loot/XP presentation pozostaje przy dotychczasowych właścicielach po B.
Client combat shared reach i reaction contract z review B nie należą do C.

Każdy powyższy etap daje działający production path i reviewowalny commit.
Zamknięty C integrujemy lokalnie przez `--no-ff` do `codex/spike-graduation`, po
sprawdzeniu diffu i właściwych kontraktów oraz odnotowaniu native acceptance.
Usuwamy tylko zmergowany local branch. Main i publikacja wymagają oddzielnej
końcowej integracji/prośby zgodnie z zatwierdzonym workflow.
