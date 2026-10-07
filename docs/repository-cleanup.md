# Czyszczenie forka Mandate of Three

Repo jest forkiem Godot Tiny MMO/Ekonia. Własny gameplay ma docelowo działać w 3D.
Plan architektury: `Mandate-of-Three_TinyMMO_Spike_Plan.pdf` w tym katalogu.

Na decyzję właściciela projektu czyszczenie zaczynamy przed spike'em 3D.
Zachowujemy minimalną ścieżkę klient -> gateway -> master -> world, aby nadal
móc sprawdzać logowanie, tworzenie postaci, wejście do instancji i replikację.

## Etap 1: mapy i oprawa 2D

Usunięte:

- wszystkie mapy Ekonia, ich tilesety i szablon mapy;
- definicje instancji tych map oraz NPC dungeon keeper odwołujący się do usuniętego dungeonu;
- pogoda 2D i jej podpięcie w kliencie oraz modelu mapy;
- zegar świata, cykl dnia/nocy, ambient light i endpoint `get.server_time`;
- efekty campfire/firefly.

Jedyna definicja instancji to `Spike`. Każde logowanie i recall kieruje do niej.
Pierwsza scena techniczna 2D została zastąpiona przez
`source/common/gameplay/maps/spike/spike_map_3d.tscn`: podłoga, ściany, przeszkody
i kapsuły graczy z serwerową fizyką 3D. Stan reworku: [spike3d.md](spike3d.md).

## Etapy 2–3: odpięte systemy gameplayu Ekonia

Usunięto poniższe systemy razem z aktywnymi wywołaniami, menu i endpointami.

| System | Usunięte powiązania |
| --- | --- |
| Basing / territory | Tick, rejestr flag mapy, obrażenia flag, menu, endpointy, API zapisu flag, territory-only guild upgrades. |
| Sparring | Matchmaking/rating, hooki śmierci i disconnectu, reguły obrażeń, tints drużyn, normalizacja equipu i poziomu, countdown, menu i endpointy. |
| Mastery | XP broni, drzewka/loadout/passives, odświeżanie na spawn/equip, replikowane pseudo-sloty specjalnych umiejętności, zakładki, komunikaty i endpointy. |
| Jobs | Profesje, XP/perks, gating i bonusy gatheringu, zakładka Jobs oraz endpointy. |
| Crafting Ekonia | Stacje i ich rejestr mapy, recipes, menu i endpoint craft.item. |
| Leaderboard | Usługa rankingu, statues, hooki kill/dungeon-clear, menu oraz endpointy. |

Character pokazuje tylko Stats. Help i welcome opisują mapę techniczną zamiast
nieistniejącej celi, Hall Keepera i zdobywania terytoriów. Gathering tymczasowo
zachowuje sam yield itemów i stały cooldown; nie nalicza XP/perków profesji.
Bronie zachowują umiejętności zapisane w scenie, a consumables własną akcję użycia.

Historyczne migracje SQLite i persisted payloads (skills/masteries/loadout,
guild statistics, flags table) pozostają dla zgodności istniejącego zapisu.
Nie ma aktywnego runtime usuniętych systemów. Przebudowa schematu i usunięcie
historycznych pól wymagają osobnego etapu przed publiczną alphą. Nowe egzemplarze
ItemInstance już działają w osobnych tabelach SQLite, niezależnie od legacy payloads.

Demo assets/audio nadal są używane przez login, pozostały UI, postać 2D i itemy.
Usuwamy je dopiero po analizie referencji lub zastąpieniu tych warstw przez 3D.

## Etap 4: drugi cleanup po pionie PvE

2026-10-07, branch `codex/second-cleanup-readme`. Użytkownik potwierdził ręcznie
działanie PvE przed tym etapem. Usunięto **157 nieużywanych assetów**, razem z ich
metadanymi `.import`: **314 plików**, około **6,92 MiB** oryginalnych assetów:

- 133 tekstury środowiska, budynków i terrainów pozostałe po usuniętych mapach;
- 6 utworów muzyki tych map: fungus, lost_woods, market, shadow_temple, shop, village;
- 13 ikon dawnych umiejętności/mastery bez pozostałych odwołań;
- 5 nieużywanych wariantów ikon menu 16px.

Pełny manifest: [cleanup-2-removed-assets.txt](cleanup-2-removed-assets.txt).
Kandydat musiał nie mieć odwołania do ścieżki ani UID w pozostałych plikach
źródłowych, scenach, zasobach, konfiguracjach i dodatkach. Uwzględniono referencje
między assetami. Foldery ładowane dynamicznie (status, daily, menu 32px, emotes,
guild trophies) nie podlegały usuwaniu. Ikony edytora, fonty, modele 2D, itemy
i zasoby wciąż powiązane z loginem lub modułami w kwarantannie pozostają.

README opisuje teraz faktyczny projekt, sterowanie, lokalny start i testy.
Upstream został ograniczony do credits oraz referencji infrastruktury; zachowano
LICENSE i informacje o autorach pozostałych assetów. Schemat SQLite i moduły
w kwarantannie nie były przebudowywane w tym cleanupie.

Weryfikacja etapu 4: brak odwołań do usuniętych ścieżek i UID w `source`,
`addons/tinymmo`, konfiguracji, testach i pozostałych assetach; import edytora
bez błędów parsowania i brakujących zasobów; wszystkie 872 zasoby źródłowe
załadowane. `run-items.ps1`, `run-spike3d.ps1` i `run-pve.ps1` zakończyły się
sukcesem, w tym test dwóch klientów bijących jednego moba i konkurencyjnego
pickupu. `git diff --check` bez błędów.

Party, guilds, trade, shops, quests, dungeon i events pozostają do osobnej oceny
zgodnie z kategorią QUARANTINE w planie. Ich obecność nie przesądza o użyciu w MVP.

## Weryfikacja

Po zmianach sprawdzamy referencje `res://` oraz UID usuniętych zasobów, import
projektu w Godot i wejście dwóch lokalnych klientów do instancji `Spike`.
Sam import nie potwierdza poprawnego logowania ani replikacji ruchu.

Weryfikacja po etapach 1–3, przed reworkiem 3D (2026-10-07), na Godot 4.7.2 z projektowego `.godot`:

- `git diff --check`: bez błędów;
- 187 usuniętych plików śledzonych w Git: brak referencji do ich ścieżek i UID w `source` oraz `addons/tinymmo`;
- import edytora: bez błędów skryptów po usunięciu konfiguracji brakującego dodatku MCP;
- 861 pozostałych skryptów, scen i zasobów z `source`: załadowane przez Godot bez błędów kompilacji i brakujących zależności;
- smoke sceny: dokładnie jedna instancja `Spike`, mapa instancjonuje się, brak NPC/warperów,
  sceny master/gateway/world ładują się;
- lokalny start czterech ról: gateway i world połączyły się z masterem, world otworzył SQLite,
  klient uruchomił scenę logowania;
- ręczny test dwóch klientów (2026-10-07): użytkownik potwierdził działanie;
  screenshot pokazuje dwa klienty z różnymi peer ID oraz postacie Dralusa i Lynanel
  widoczne w obu oknach. Wejście dwóch klientów do świata i wzajemna widoczność
  postaci są potwierdzone;
- synchronizacja ruchu w obie strony: użytkownik potwierdził w ręcznym teście
  dwóch klientów (2026-10-07);
- reconnect: jeszcze niesprawdzony.

Procesy testowe zakończyły się automatycznie po ograniczonej liczbie klatek.
Logi zawierają komunikat o dostępie do systemowego magazynu certyfikatów Windows
oraz zasobach pozostałych przy zamykaniu. Nie uznajemy tego za całkowicie czysty
runtime. Headless nie potwierdza wyglądu UI/mapy.

Do lokalnego uruchomienia potrzebne są role `master-server`, `gateway-server`,
`world-server` i dwa procesy `client`. Punkt wejścia obsługuje feature tags oraz
argument `--mode=<rola>` przed separatorem `--` Godota (aktualny parser używa
`OS.get_cmdline_args()`).
