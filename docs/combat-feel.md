# Combat Feel Pass

Stan: 2026-10-07, branch `codex/combat-feel-pass`. Rozszerzenie działającego pionu
PvE, bez zmiany schema SQLite i bez rozbudowy item progression.

## Sterowanie i walka

- WASD: ruch i kierunek postaci; I: ekwipunek; E: najbliższy łup.
- Przytrzymana Spacja: powtarzane zamachy przed postacią, także bez celu.
- LPM: opcjonalne zaznaczenie psa; kliknięcie poza mobem usuwa zaznaczenie.
- F: autoatak na zaznaczonego psa, z prostym podejściem i obrotem.
  Ręczny ruch, śmierć gracza lub celu przerywa autoatak.

Klient wysyła tylko `request_attack(sequence)`; nie podaje ID celu, obrotu,
obrażeń ani listy trafień. Serwer sprawdza sesję, żywego gracza, monotoniczną
sekwencję int32 i recovery. Pobiera atak z runtime equipment/stats, zapamiętuje
serwerowy kierunek postaci i rozpoczyna zamach. Atak pochodzi teraz z runtime
statów załadowanych przy wejściu i odświeżanych po commit itemów, bez query przy
zamachu; patrz [persistence policy](persistence-policy.md). Nietrafiony zamach zużywa etap
combo i recovery. Ruch gracza jest blokowany na czas recovery.

Trafienie jest rozstrzygane po windupie przez zapytanie fizyki na warstwie mobów:
zasięg 2,4 m, sektor ±65° przed postacią, różnica wysokości do 1,2 m oraz
nieprzesłonięta linia w warstwie świata. Wszystkie kwalifikujące się psy otrzymują
obrażenia raz w danym zamachu; cel zaznaczony przez klienta nie wpływa na wynik.
Broad phase pobiera do 64 colliderów, co pokrywa obecną arenę z czterema psami.

| Etap | Windup | Recovery | Obrażenia | Reakcja żywego moba |
| --- | --- | --- | --- | --- |
| 1 | 120 ms | 450 ms | atak z ekwipunku | 120 ms hit stun |
| 2 | 140 ms | 450 ms | atak z ekwipunku | 120 ms hit stun |
| 3 | 180 ms | 700 ms | 1,5 × atak, zaokrąglony w dół | 350 ms hit stun i odrzut |

Przerwa ponad 1100 ms między przyjętymi zamachami rozpoczyna combo od etapu 1.
Odrzut ma początkową prędkość 7 m/s od gracza i wygasa przy serwerowej fizyce;
kolizje ze światem nadal obowiązują. Zgon przed impactem anuluje rozpoczęty
zamach. Powtórzone sekwencje i spam nie obchodzą recovery.

To parametry naszego prototypu, nie deklaracja dokładnego balansu ani limitów
oryginalnego Metina. Cel jest przygotowany jako pomoc autoataku; skille nie są
jeszcze wdrożone.

## Wild Dogi, nawigacja i śmierć

Arena ma cztery psy po 120 HP. AI zachowuje `IDLE → CHASE → ATTACK → RETURN`.
Aggro wynosi 6 m, leash 12 m od domu, zasięg ataku 1,65 m. Pies zadaje 6 obrażeń
co 1200 ms, jeżeli gracz jest żywy, widoczny i mob nie jest w hit stun.
Utrata celu lub wyjście poza leash uruchamia powrót do domu i odzyskanie HP.

Serwer jednorazowo wypieka navmesh małej areny ze StaticBody3D warstwy świata.
Każdy pies korzysta z NavigationAgent3D i idzie do kolejnych punktów ścieżki
przez CharacterBody3D. Ścieżki są odświeżane co 200 ms; zapytania czekają na
synchronizację mapy nawigacji. Przeszkody są uwzględnione podczas wypiekania.
Podejście korzysta z [natywnego navmeshu Godota](https://docs.godotengine.org/en/4.5/tutorials/navigation/navigation_using_navigationmeshes.html).
Autoatak gracza ma proste podejście w stronę celu, bez własnego pathfindingu.

Gracz ma 100 HP. Przy zerowym HP serwer zatrzymuje ruch, anuluje zamach i combo,
blokuje kolejne ataki i pickup. Klient pokazuje przewróconą kapsułę i odliczanie.
Po 2 s serwer odradza gracza w punkcie startowym z 100 HP; następny zamach zaczyna
combo od 1. Pies odradza się po 6 s. Są to automatyczne respawny prototypu.

Śmierć każdego psa tworzy osobny łup na ziemi. Własność liczy się z faktycznie
zadanych obrażeń. Rezerwacja 15 s, lifetime 120 s, pełna torba i atomowe claimy
pozostają jak w [pionie PvE](pve-ground-loot.md). Podniesiony egzemplarz zachowuje
UID po relogu; HP, pozycje i niepodniesiony loot pozostają stanem runtime.

## Prezentacja i granice

Psy mają proceduralne modele zastępcze z pudełek. Kapsuła gracza porusza bronią
i pokazuje łuk zamachu; finał ma złoty efekt. Trafienie powoduje błysk modelu,
krótkie zatrzymanie moba i fizyczny odrzut finału. Snapshoty mobów, HP, combo
i respawnu są rozsyłane przy 10 Hz; klienci interpolują ruch.

Nie ma jeszcze docelowego rigu i animacji, PvP, skilli, lokalnej predykcji ani
AOI. Nawigacja jest dla statycznej, małej areny, bez avoidance tłumu i przebudowy
navmeshu w trakcie gry. Kolejny etap item progression wymaga osobnego zakresu.

## Weryfikacja

```powershell
& .\tests\run-combat.ps1
& .\tests\run-pve.ps1
& .\tests\run-spike3d.ps1
& .\tests\run-items.ps1
```

`run-combat` uruchamia serwer i dwa klienty WebSocket na porcie 18098 z bazą
testową. Uruchamiaj go kolejno z `run-pve`, który używa tego samego portu.
Test sprawdza dwa psy z przodu oraz nietrafione psy z boku i z tyłu, ignorowanie
zaznaczonego celu, spam/replay, etapy i reset combo, rzeczywisty odrzut, omijanie
centralnej przeszkody, powrót i leczenie psa, śmierć podczas windupu, blokadę
inputu/ataku/pickupu po śmierci oraz ponowny atak po respawnie. Oba klienty
potwierdzają replikowane trafienia, efekt finału, śmierć i odrodzenie tego samego
gracza. Markery: `COMBAT_SERVER_OK` i dwa `COMBAT_CLIENT_OK`.

Istniejący test PvE nadal sprawdza dwóch graczy bijących tego samego psa,
ownership, pełną torbę, double pickup i trwałość UID po ponownym otwarciu SQLite.
Pełne logowanie przez gateway/master/world sprawdzono także `tests/pve_session.tscn`:
walka, ground loot, pickup i dokładny UID po relogu. Wygenerowano i obejrzano
podglądy renderu combo i łupu w `.godot/verification`.

Import i załadowanie 873 źródłowych skryptów/scen/zasobów przeszły bez błędów
parsowania. W logach pozostają wcześniejsze komunikaty silnika o magazynie
certyfikatów i zasobach przy zamykaniu. Ręczne wyczucie sterowania i timingów
na pulpicie pozostaje do oceny użytkownika.
