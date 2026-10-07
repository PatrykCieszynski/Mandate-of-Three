# Mandate of Three

Multiplayer 3D inspirowany Metinem 2, budowany w Godot na infrastrukturze
[Godot Tiny MMO](https://github.com/SlayHorizon/godot-tiny-mmo).
Repo zawiera działający techniczny vertical slice; to jeszcze nie alpha gry.

## Aktualny zakres

- Gateway, master i world: logowanie, sesje, tworzenie postaci i wejście do instancji.
- Spike 3D: serwerowy ruch i fizyka, kolizje, interpolacja zdalnych postaci.
- ItemDefinition i trwałe ItemInstance: UID, właściciel, bonusy, equip konkretnego
  egzemplarza oraz transakcyjny zapis SQLite.
- Pierwsza progresja przez loot: atak broni na ziemi, porównanie z założonym
  egzemplarzem, podgląd ataku po zmianie oraz trwały equip podniesionego miecza.
- Cztery Wild Dogi z nawigacją i serwerowym AI; kierunkowe melee trafiające wiele
  celów, trzyciosowe combo, reakcja na trafienie i odrzut ostatniego ciosu.
- Śmierć i respawn gracza oraz mobów, loot na ziemi, rezerwacja i trwały pickup.
  Testy dwóch klientów obejmują walkę, śmierć i rywalizację o ten sam łup.

Sterowanie: **WASD** — ruch, **I** — ekwipunek, **przytrzymaj Spację** — combo
przed postacią, **E** — podnieś najbliższy łup. **LPM** zaznacza opcjonalny cel,
**F** przełącza autoatak; ręczny ruch przerywa autoatak.

AI omija przeszkody na navmeshu areny. Niepodniesiony loot oraz HP
i pozycja są stanem runtime; przedmiot po pickupie jest trwały. AOI, local
prediction, docelowe modele i animacje pozostają do kolejnych etapów.
Starsze moduły upstreamu w repo nie oznaczają funkcji dostępnych w naszym 3D.

## Lokalne uruchomienie

Zweryfikowany silnik: **Godot 4.7.2**, lokalnie w `.godot/`.
Godot i binaria dodatku godot-sqlite nie są wersjonowane; nowy checkout wymaga
ich lokalnej instalacji. Folder `.godot` zawiera lokalny cache, silnik i wyniki testów.

Uruchom trzy role w osobnych terminalach PowerShell, z katalogu projektu:

```powershell
& .\.godot\Godot_v4.7.2-stable_win64_console.exe --headless --path . --mode=master-server
& .\.godot\Godot_v4.7.2-stable_win64_console.exe --headless --path . --mode=gateway-server
& .\.godot\Godot_v4.7.2-stable_win64_console.exe --headless --path . --mode=world-server
```

Następnie uruchom klienta, a do testu multiplayer dwa klienty:

```powershell
& .\.godot\Godot_v4.7.2-stable_win64.exe --path . --mode=client
```

Można też użyć Godot **Debug → Customize Run Instances** z osobnymi feature tags
`master-server`, `gateway-server`, `world-server` i `client`. Argument `--mode`
podawaj przed separatorem `--`. Domyślne konfiguracje są w `data/config/`.
Konta i bazy świata są lokalnymi danymi runtime wykluczonymi z Git.

## Testy i workflow

```powershell
& .\tests\run-items.ps1
& .\tests\run-spike3d.ps1
& .\tests\run-pve.ps1
& .\tests\run-combat.ps1
& .\tests\run-progression.ps1
```

Testy używają baz testowych; `run-pve`, `run-combat` i `run-progression` współdzielą port 18098,
więc uruchamiaj je kolejno. Pełne logowanie/relog przez zwykłe serwery
opisują dokumenty itemów i PvE; te scenariusze tworzą lokalne konta testowe.
Nowe zmiany robimy na branchach `codex/<temat>`, sprawdzamy i mergujemy lokalnie
z `--no-ff`. Zasady: [AGENTS.md](AGENTS.md).

## Dokumentacja

- [Kierunek i priorytety projektu](docs/project-direction.md)
- [Spike 3D i transport ruchu](docs/spike3d.md)
- [Egzemplarze przedmiotów i trwały zapis](docs/item-instances.md)
- [PvE, ground loot i pickup](docs/pve-ground-loot.md)
- [Combat Feel Pass i aktualne sterowanie](docs/combat-feel.md)
- [Item Progression Slice: porównanie, equip i obrażenia](docs/item-progression.md)
- [Cleanup i pozostałe zależności](docs/repository-cleanup.md)
- [Analiza Open-MT2 jako referencji](docs/open-mt2-analysis.md)
- [Pierwotny plan spike'a](docs/Mandate-of-Three_TinyMMO_Spike_Plan.pdf)

## Upstream i credits

Fork zachowuje infrastrukturę Godot Tiny MMO autorstwa **slayhorizon**:
[repozytorium upstream](https://github.com/SlayHorizon/godot-tiny-mmo) i
[dokumentację infrastruktury](https://slayhorizon.github.io/godot-tiny-mmo/).
Upstreamowe mapy były autorstwa **higaslk**, a część pozostałych assetów pochodzi
z prac **Anokolisa / Dungeon Crawler Pixel Art Asset Pack**. Podziękowania upstreamu
obejmują również Jackiefrost, d-Cadrius i pozostałych współtwórców.

Open-MT2 jest referencją zachowania Metina, bez importu kodu, assetów ani runtime.
Licencja kodu upstreamu: [MIT](LICENSE), z zachowanym notice praw autorskich.
