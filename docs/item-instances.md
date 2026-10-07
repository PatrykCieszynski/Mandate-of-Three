# Egzemplarze przedmiotów — Spike 3D

Stan: 2026-10-07. Nowy model działa w Spike 3D przez istniejące logowanie
gateway/master/world. Panel otwiera się klawiszem **I**, zamyka przez I, Esc lub
przycisk. Otwarty panel zatrzymuje wysyłanie kierunku ruchu.

## Model i działający zakres

`ItemDefinition` jest wspólnym Resource z ID definicji, nazwą, slotem, limitem
stacka, bazowymi statystykami i przyrostem na poziom ulepszenia. Definicja nie
przechowuje właściciela ani wylosowanych bonusów.

`ItemInstance` opisuje konkretny egzemplarz: UID, ID definicji, trwałe ID postaci,
ilość, poziom ulepszenia, affixy, sockety, wersję oraz położenie w torbie lub slocie.
UID to 16 losowych bajtów z Crypto, zapisanych jako 32 znaki hex. Istniejący UID
jest odczytywany z SQLite; logowanie nie generuje go ponownie.

Pierwsze wejście postaci do Spike przyznaje jednorazowo zestaw techniczny:

| Egzemplarz | Definicja | Bonus ataku | Atak broni | Atak postaci po założeniu |
| --- | --- | --- | --- | --- |
| Pierwszy miecz | `iron_sword` | +3 | 13 | 23 |
| Drugi miecz | `iron_sword` | +7 | 17 | 27 |

Bazowy atak postaci wynosi 10. Bonusy zestawu są celowo ustalone, aby powtarzalnie
sprawdzać rozdzielenie egzemplarzy. Torba ma 24 miejsca, a wyposażenie jeden slot
`weapon`. Założenie kolejnej broni oddaje poprzednią do zwalnianego miejsca torby.
Zdjęcie broni wymaga wolnego miejsca. Panel pokazuje UID w skrócie, ale wysyła
pełny UID. Model obsługuje zapis poziomu +0…+9 i socketów; działania ulepszania,
wkładania kamieni i rerollowania nie są jeszcze zaimplementowane.

## Autorytatywny zapis i synchronizacja

Migracja WorldSchema **v10** dodaje trzy tabele, zachowując wcześniejsze dane:

- `item_instances`: UID, właściciel, definicja, ilość, ulepszenie, JSON bonusów
  i socketów oraz wersja.
- `item_placements`: UID, właściciel i dokładne miejsce. Indeksy unikalne chronią
  miejsce w torbie oraz slot wyposażenia danej postaci.
- `item_initializations`: trwały marker przyznania zestawu. Nawet pusta torba
  nie powoduje ponownego przyznania przedmiotów przy logowaniu.

Stary serializer PlayerResource nie zapisuje tych tabel. Nie importujemy
automatycznie starego inventory JSON ani jego założonej broni. Tabele nie mają
klucza obcego do `players`, ponieważ legacy zapis używa `INSERT OR REPLACE`.
Inicjalizacja sprawdza istnienie postaci; operacje filtrują właściciela w obu
tabelach. Przyszłe usuwanie postaci będzie wymagać jawnego sprzątania jej
egzemplarzy, położeń i markera inicjalizacji.

Klient wysyła wyłącznie akcję, UID i oczekiwaną wersję. Serwer bierze ID postaci
z uwierzytelnionej sesji nadawcy RPC, sprawdza własność, wersję i slot oraz ogranicza
częstotliwość poleceń do jednego na 100 ms. Zmiana odbywa się w `BEGIN IMMEDIATE`:
położenia obu broni i ich wersje są zatwierdzane razem. Błąd wycofuje całość.
Snapshot wraca po transakcji; statystyki są liczone na serwerze z zapisanych
egzemplarzy. Nie ma oddzielnego cache wymagającego zapisu przy wylogowaniu.

Pełny ekwipunek trafia tylko do właściciela. Inni gracze dostają ID definicji
założonej broni i widzą prosty model miecza przy kapsule. Nowy gracz otrzymuje także
stan broni obecnych graczy. Statystykę ataku wykorzystuje już
[serwerowa walka z mobem 3D](pve-ground-loot.md).

[Pierwszy Item Progression Slice](item-progression.md) dodaje porównanie z założoną
bronią, podgląd ataku po zmianie i oznaczenie nowego łupu. Znaleziony egzemplarz
można założyć i zachować razem ze statystykami po relogu.

## Weryfikacja

```powershell
# Osobna baza SQLite: nie wymaga uruchomionych serwerów.
& .\tests\run-items.ps1

# Wymaga normalnego gateway/master/world; tworzy dwa lokalne konta gościa
# i postacie testowe w ich zwykłych magazynach danych.
& .\tests\run-items.ps1 -WithSession

# Regresja sieci i fizyki 3D, osobny port i sesje fixture.
& .\tests\run-spike3d.ps1
```

Wszystkie testy zakończyły się sukcesem na projektowym Godot 4.7.2:

- SQLite: osobne UID i bonusy, exact equip/swap, własność, odrzucenie starej wersji,
  unequip, zachowanie legacy profilu, izolacja od starego zapisu, ponowne otwarcie
  bazy z identycznym stanem oraz brak ponownego przyznania zestawu.
- Wstrzyknięcie błędu SQL podczas zamiany broni: obie lokalizacje i wersje
  wracają do stanu sprzed operacji; kolejna poprawna transakcja działa.
- Dwa klienty z pełnym logowaniem: statystyki 23/27, wybór konkretnego UID,
  odrzucenie starej wersji przez RPC, widoczna broń obu postaci i relog z identycznym
  snapshotem UID/bonusów/wyposażenia/wersji.
- Test sieci/fizyki 3D nadal przechodzi dla serwera i dwóch klientów.
- Załadowanie wszystkich 871 skryptów, scen i zasobów źródłowych; brak błędów
  parsowania. Render OpenGL panelu i broni wygenerowany i obejrzany.

Logi i obraz podglądu są w ignorowanym `.godot/verification`. Test SQLite celowo
wywołuje jeden błąd SQL przy sprawdzaniu rollbacku. Nadal występują wcześniejsze
komunikaty silnika o magazynie certyfikatów Windows i zasobach przy zamknięciu.

## Następny krok

Mob PvE, serwerowe obrażenia i pickup nowego egzemplarza są opisane w
[pionie PvE](pve-ground-loot.md). Handel, upgrade i reroll powinny później używać
tego samego modelu oraz atomowych operacji na egzemplarzu.
