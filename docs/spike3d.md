# Spike 3D — pierwszy etap

Stan: 2026-10-07. Domyślna instancja `Spike` uruchamia teraz natywną mapę 3D.

## Działający zakres

- Podłoga 32×32 m, ściany i dwie przeszkody ze StaticBody3D.
- Gracze jako kapsuły CharacterBody3D z nazwą, kolorem i znacznikiem kierunku.
- Kamera perspektywiczna śledząca lokalną postać z góry.
- Ruch WASD po płaszczyźnie XZ, grawitacja i kolizje 3D.
- Logowanie i handoff przez istniejący gateway, master i world.
- Dołączanie, lista graczy, snapshoty ruchu i usuwanie odłączonych postaci.
- Panel ekwipunku pod I, wyposażenie po UID i zapis egzemplarzy w SQLite;
  [model przedmiotów i testy](item-instances.md).

Klient wysyła numer sekwencji i kierunek Vector2 przy 20 Hz. Serwer normalizuje
kierunek, odrzuca wartości niefinitywne oraz powtórzone/stare sekwencje, a fizykę
CharacterBody3D wykonuje przy 60 Hz z prędkością 5 m/s. Brak świeżego inputu
przez 250 ms zatrzymuje ruch. Utrata fokusu okna wysyła zerowy kierunek.
Snapshoty Vector3 + yaw wracają przy 20 Hz; klienci interpolują pozycję i obrót.
Pierwszy snapshot lokalnego gracza kończy ekran ładowania.

Identyfikator gracza jest pobierany z nadawcy RPC. Dołączenie wymaga zarówno
`awaiting_peers` konkretnej instancji, jak i uwierzytelnionej PlayerResource
w WorldServer. Klient nie podaje własnej pozycji ani ID sterowanej postaci.

## Granica migracji

`spike_instance_3d.gd` po stronie klienta i serwera to adaptery istniejącego
cyklu instancji. Dziedziczą typy używane przez menedżery sesji, ale nie uruchamiają
starych Player/LocalPlayer/Map2D ani StateSynchronizer z polami Vector2.
Nowy współdzielony endpoint SpikeWorld3D ma ten sam node path i konfigurację RPC
po obu stronach. `InstanceResource.use_3d` wybiera adapter serwera, a klient
rozpoznaje typ załadowanej sceny.

Legacy HUD, walka, NPC i interakcje pozostają do portowania. Spike ma własny
panel przedmiotów, prosty model założonej broni i małą nakładkę z instrukcją ruchu
i liczbą graczy. Stary inventory/equip nie obsługuje nowej mapy. Obecny transport
oraz sesje TinyMMO pozostają podstawą projektu. Domyślna mapa techniczna 2D została
zastąpiona; pozostałe klasy 2D są nadal zależnościami modułów w kwarantannie.

Pozycja 3D jest na tym etapie stanem runtime. Ponowne wejście tworzy kapsułę na
punkcie startowym; starego `last_position` Vector2 nie reinterpretujemy jako
współrzędnych 3D. Trwały zapis pozycji wymaga osobnego, jawnego rozszerzenia modelu.
Nie ma jeszcze predykcji lokalnego ruchu, AOI ani limitu liczby graczy dla broadcastu
snapshotów. Pierwszy etap jest przeznaczony do małego lokalnego spike'a.

## Pliki

| Plik | Odpowiedzialność |
| --- | --- |
| `source/common/gameplay/spike3d/spike_world_3d.gd` | Arena, wspólne RPC, kontrola inputu, snapshoty, kamera i nakładka. |
| `source/common/gameplay/spike3d/spike_character_3d.gd` | Ciało i kolizja kapsuły, serwerowa fizyka, interpolacja klienta. |
| `source/common/gameplay/maps/spike/spike_map_3d.tscn` | Scena domyślnej mapy Spike. |
| `source/server/world/components/spike_instance_3d.gd` | Adapter instancji serwera. |
| `source/client/network/spike_instance_3d.gd` | Adapter instancji klienta. |
| `tests/spike3d_network.gd` | Test dwóch klientów przez WebSocket, bez zmian kont i bazy. |
| `tests/run-spike3d.ps1` | Uruchomienie trzech procesów i sprawdzenie kodów wyjścia oraz markerów testu. |

## Weryfikacja

Godot 4.7.2 z projektowego `.godot`:

- Import edytora: brak błędów parsowania nowych skryptów.
- Wszystkie 872 skrypty, sceny i zasoby źródłowe zostały załadowane
  po dodaniu modelu egzemplarzy i pionu PvE.
- Test WebSocket: serwer + dwa headless klienty, wszystkie trzy procesy exit 0.
  Potwierdzono listę dwóch graczy, ruch widziany przez drugiego klienta, ograniczenie
  prędkości mimo dużego kierunku, odrzucenie replay/NaN, zatrzymanie po wygaśnięciu
  inputu, kolizję ze ścianą/przeszkodą i cleanup po disconnect.
- Pełne wejście przez gateway/master/world: dwa lokalne konta gościa i nowe
  postacie testowe; oba klienty otrzymały stan 3D i widziały ruch drugiej postaci.
  Fixture pełnego logowania i logi są w ignorowanym `.godot/verification`.
- Render OpenGL: wygenerowano i obejrzano podgląd areny oraz dwóch kapsuł.
- Ręczny test 3D na pulpicie użytkownika: użytkownik potwierdził działanie
  po uruchomieniu dwóch klientów (2026-10-07). Jest to potwierdzenie ogólne;
  reconnect i trwały zapis pozycji pozostają poza tym testem.

Powtarzalny test sieci/fizyki z katalogu projektu:

```powershell
& .\tests\run-spike3d.ps1
```

Test używa osobnego portu 18097. Fixture dostarcza lokalne zasoby sesji,
więc nie wymaga uruchomienia gateway/master/world i nie testuje ich autoryzacji.
Pełny handoff sprawdzono oddzielnie. Logi pozostają w `.godot/verification`.
W środowisku nadal pojawiają się wcześniejsze komunikaty o magazynie certyfikatów
Windows i zasobach przy zamykaniu; nie są to błędy nowych skryptów, lecz runtime
nie jest całkowicie wolny od komunikatów silnika.

## Następny etap

ItemDefinition/ItemInstance, equip po UID i trwały zapis są wdrożone.
[Pion PvE z mobem i ground loot](pve-ground-loot.md) dodaje pierwszy przepływ
walki, śmierci i pickupu. Dalsze priorytety opisuje [kierunek projektu](project-direction.md).
