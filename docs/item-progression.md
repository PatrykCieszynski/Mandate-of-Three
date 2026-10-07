# Item Progression Slice — pierwszy krok

Stan: 2026-10-07, branch `codex/item-progression-slice`. Mała pętla oparta na
istniejącym modelu egzemplarzy: zabij psa → zobacz broń na ziemi → podnieś →
porównaj → załóż → zadawaj obrażenia z nowej broni → zachowaj ją po relogu.

## Zachowanie w grze

Łup nadal jest żelaznym mieczem z serwerowym bonusem ataku +1…+9. Etykieta na
ziemi i komunikat po pickupie pokazują atak konkretnej broni, czyli 11…19.
Podniesienie dodaje przedmiot do torby; nie zakłada go automatycznie.

Panel pod I pokazuje atak postaci oraz aktualną broń. Założony egzemplarz jest
na początku, potem ostatnio podniesiony przedmiot oznaczony jako „nowy”, a dalej
pozostałe przedmioty według ataku. To kolejność prezentacji; miejsca w torbie,
snapshot i zapis SQLite pozostają bez zmian. UID jest dostępny w tooltipie nazwy.

Każda broń w torbie pokazuje **atak postaci po założeniu** i różnicę względem
obecnej broni. Zielony oznacza wzrost ataku, czerwony spadek, szary brak zmiany.
Podgląd odejmuje atak założonego egzemplarza i dodaje atak porównywanego:

| Sytuacja | Obecny atak postaci | Atak znalezionej broni | Po założeniu |
| --- | --- | --- | --- |
| Starter z bonusem +3 | 23 | 19 | 29 (+6) |
| Starter z bonusem +7 | 27 | 19 | 29 (+2) |
| Starter z bonusem +7 | 27 | 13 | 23 (−4) |
| Brak broni | 10 | 13 | 23 (+13) |

Różnica dotyczy ataku, nie ogólnej jakości przedmiotu. Trzeci cios combo nadal
korzysta z mnożnika 1,5, a pozostałe reguły opisuje [Combat Feel Pass](combat-feel.md).

## Serwer i trwałość

Podgląd wykorzystuje statystyki instancji policzone przez serwer i nie jest
wysyłany jako polecenie. Equip nadal przyjmuje akcję, UID i revision; serwer
sprawdza właściciela i zapisuje zamianę atomowo. Combat pobiera aktualny atak
z SQLite na początku zamachu. Identyczny pierwszy cios może zatem zadać 23
obrażenia starterem i 29 obrażeń podniesionym mieczem z bonusem +9.

UID, bonus, położenie i revision podniesionej i założonej broni przetrwają relog.
Oznaczenie „nowy” i komunikat pickupu są lokalną prezentacją tej sesji i nie są
nowymi danymi trwałymi. Rezerwacja łupu, pełna torba, double pickup i durable claim
pozostają jak w [pierwszym pionie PvE](pve-ground-loot.md).

Nie zmieniono parametrów walki, losowania bonusów, zestawu technicznego dwóch
starterów ani schema v11. Jest to pierwsza progresja przez wybór lepszego
egzemplarza, bez XP, poziomów, upgrade action, rarities, craftingu czy nowych
rodzajów broni. Dalszy zakres progression wymaga osobnej decyzji.

## Weryfikacja

```powershell
# Izolowana baza, serwer i dwa klienty; nie potrzebuje zwykłych serwerów.
& .\tests\run-progression.ps1

# Ten sam test z renderem panelu jednego z klientów.
& .\tests\run-progression.ps1 -Preview

# Pełne logowanie, porównania i relog; wymaga gateway/master/world.
& .\tests\run-items.ps1 -WithSession

# Regresje; uruchamiaj kolejno z progression, bo współdzielą port 18098.
& .\tests\run-pve.ps1
& .\tests\run-combat.ps1
```

Test progression wykonuje produkcyjne RPC walki, pickupu i equipu. Fixture
ustawia bonus utworzonego przez śmierć psa dropu na +9, aby wynik nie zależał
od RNG; kod produkcyjnego losowania pozostaje bez zmian. Sprawdza brak nadania
przed pickupem, opis broni na ziemi, dokładny UID, podgląd 29 (+6), niemutowanie
snapshotu przez UI, prywatność ekwipunku drugiego gracza, rzeczywiste obrażenia
23 → 29 oraz identyczny zapis po ponownym otwarciu SQLite i inicjalizacji.
Markery: `PROGRESSION_SERVER_OK` oraz dwa `PROGRESSION_CLIENT_OK`.

Test pełnych sesji ekwipunku sprawdza podgląd lepszej, słabszej i równej broni,
a także podgląd bez założonej broni. `tests/pve_session.tscn` dodatkowo przechodzi
przez zwykły gateway/master/world: zabicie psa, pickup losowego egzemplarza,
porównanie, założenie oraz relog z identycznym snapshotem.

Podgląd `item-progression-preview.png` w `.godot/verification` został wygenerowany
i obejrzany; porównanie nowego miecza i przycisk Załóż są widoczne bez scrolla.
Pełna sesja generuje też `pve-item-comparison-preview.png` i
`pve-item-equipped-preview.png`. Źródłowe 873 skrypty/sceny/zasoby załadowano
bez błędów parsowania. W środowisku pozostają wcześniejsze komunikaty silnika
o magazynie certyfikatów oraz zasobach przy zamykaniu.
