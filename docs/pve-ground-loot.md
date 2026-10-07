# Vertical slice PvE — jeden mob i ground loot

Stan: 2026-10-07. Minimalny pion na branchu `codex/pve-ground-loot`:

`Player → Mob → Combat → Death → Ground Loot → Pickup → Persistent Item`

## Gra i autorytet

**WASD**: ruch; **I**: ekwipunek; **Spacja**: atak strażnika; **E**: podnieś
najbliższy łup. Podejdź do celu na około 2 m. Mob jest czerwoną kapsułą z nazwą
i HP, łup złotym przedmiotem na ziemi z nazwą i rezerwacją.

Serwer liczy obrażenia z aktualnego ekwipunku SQLite: atak 10 bez broni, 23 lub 27
z mieczem startowym. Klient wysyła sekwencję i ID jedynego znanego moba, bez
obrażeń, pozycji ani własnego ID. Wymagane są żywy gracz, dystans ≤2,4 m,
nieprzesłonięta linia w warstwie świata i cooldown **600 ms**. Monotoniczna
sekwencja int32 odrzuca replay; spam nie zwiększa częstotliwości obrażeń.

## Mob i AI

Jeden strażnik: 120 HP, prędkość 2,8 m/s, dom `(-4, 0, 0)`.
AI wykonuje się w fizyce serwera przy 60 Hz:

| Stan | Zachowanie |
| --- | --- |
| IDLE | Wybiera najbliższego żywego gracza w promieniu 6 m z widoczną linią. |
| CHASE | Idzie do celu z kolizjami CharacterBody3D. |
| ATTACK | W zasięgu 1,8 m zadaje 4 obrażenia co sekundę. |
| RETURN | Po utracie celu lub przekroczeniu leasha 10 m wraca do domu, odzyskuje HP i resetuje udział graczy w obrażeniach. |
| DEAD | Tworzy jeden łup, znika i odradza się po 6 sekundach. |

RETURN jest niewrażliwy na ataki. Śmierć jest jednorazowym przejściem; dalsze
polecenia nie tworzą kolejnego lootu. Player ma 100 HP. Przy zerowym HP traci ruch,
atak i pickup; po 2 sekundach wraca do punktu startowego z pełnym HP. HP i pozycja
pozostają stanem runtime. Nie ma nawigacji wokół przeszkód: prosty pościg może
zatrzymać moba na ścianie. Brak animacji ataku, combosów, PvP, wielu celów i
walidacji facing ataku.

## Ground loot i własność

Śmierć tworzy jeden runtime drop: unikalny UID, pozycja, `iron_sword` i bonus
ataku +1…+9 wybrany przez serwer. Przez **15 sekund** ma go zarezerwowanego
postać z największym udziałem w obrażeniach; remis rozstrzyga niższe trwałe ID.
Rezerwacja jest powiązana z postacią, więc relog i zmiana peer ID jej nie zmieniają.
Potem loot jest publiczny; niepodniesiony znika po **120 sekundach**.

Klient wysyła sam UID. Serwer sprawdza żywego gracza, istniejący/niewygasły drop,
własność, zasięg ≤2,5 m, widoczną linię i miejsce w torbie. Nie przyjmuje definicji,
bonusu ani odbiorcy od klienta.

SQLite **schema v11** dodaje `ground_item_claims` z unikalnym UID dropu.
Jedna transakcja zapisuje potwierdzenie odbioru, ItemInstance z tym samym UID i
miejsce w torbie. Dopiero po COMMIT serwer usuwa drop i aktualizuje prywatny
inventory snapshot. Pełna torba lub błąd SQL pozostawia łup na ziemi; rollback
wycofuje też potwierdzenie. Dwa RPC dla tego samego dropu mają jednego zwycięzcę.
Trwałe potwierdzenie blokuje ponowne przyznanie UID także po otwarciu bazy.

Niepodniesiony loot nie jest zapisany na dysku: restart world usuwa runtime dropy.
Zatwierdzony pickup jest trwały. Mob/HP/dropy są replikowane co 100 ms do małej
instancji; klienci interpolują ruch moba. AOI i local prediction pozostają później.

## Testy

```powershell
# Izolowana SQLite i WebSocket 18098, bez zwykłych kont i world DB.
& .\tests\run-pve.ps1

# Regresja itemów i fizyki sieciowej.
& .\tests\run-items.ps1
& .\tests\run-spike3d.ps1
```

Testy przeszły na projektowym Godot 4.7.2:

- IDLE → CHASE → ATTACK → RETURN → IDLE, obrażenia moba i reset HP.
- Zasięg, przeszkoda, replay/nieznany mob oraz cooldown przy spamie dwóch klientów.
- Obaj gracze biją tego samego moba; jedna śmierć tworzy jeden drop, bez przyznania
  przedmiotu przed pickupem.
- Rezerwacja, pełna torba, pickup z daleka, konkurencyjny publiczny pickup,
  jeden zwycięzca i brak dupe po ponowieniu.
- Rollback przy wymuszonym błędzie placement po częściowym zapisie; trwałość
  UID, bonusu, miejsca i potwierdzenia po ponownym otwarciu SQLite.
- Obaj klienci widzą HP, śmierć i ground loot; tylko zwycięzca otrzymuje item.

`tests/pve_session.tscn` sprawdził oddzielnie prawdziwe gateway/master/world:
equip, zabicie moba, loot, pickup i relog z identycznym snapshotem przedmiotów.
Tworzy lokalne konto gościa i postać; wymaga spokojnej normalnej instancji Spike:

```powershell
& .\.godot\Godot_v4.7.2-stable_win64_console.exe --headless --path . --mode=client res://tests/pve_session.tscn
```

Render OpenGL rzeczywistej sesji został wygenerowany i obejrzany. Logi i obrazy
są w ignorowanym `.godot/verification`. Ręczny test etapu przez użytkownika
pozostaje do wykonania. Techniczny respawn gracza nie ma osobnego testu
integracyjnego. Wcześniejsze komunikaty silnika o certyfikatach i zasobach przy
zamknięciu nadal występują.

Import edytora i załadowanie wszystkich 872 skryptów, scen oraz zasobów źródłowych
zakończyły się bez błędów parsowania. Regresja pełnego equip/relog dwóch klientów
przez gateway/master/world również przeszła po dodaniu walki.
