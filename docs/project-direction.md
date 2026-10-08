# Przyjęty kierunek projektu

Decyzje po review użytkownika, 2026-10-07:

- Tiny MMO jest infrastrukturą forka. Zachowujemy gateway/master/world,
  auth i sesje, lifecycle instancji, transport/replikację i persistence.
- Ruch, walka i pickup mają autorytet serwera; klient wysyła intencje.
- ItemDefinition i persistent ItemInstance z UID, owner, placement, upgrade,
  affixami, socketami i revision pozostają docelowym kierunkiem. Atomowy
  equip/swap oraz rollback są fundamentem ekonomii.
- Open-MT2 jest referencją zachowania Metina, nie runtime ani dependency.
- Obecny model itemów wystarcza; nie rozbudowujemy crafting/item frameworka.
- Priorytet: Player → Mob → Combat → Death → Ground Loot → Pickup → Persistent
  Item, z testem dwóch klientów bijących jednego moba.
- Loot leży na ziemi. Sprawdzamy własność, pełną torbę i double pickup.
- AOI później: najpierw rozważyć reuse gridu Tiny MMO na płaszczyźnie XZ.
  Local prediction też może poczekać.
- Legacy schema jest przejściowe. Przed publiczną alphą potrzebny jest własny
  czystszy reset lub migracja; nie obiecujemy trwałej kompatybilności Ekonia.
- Po vertical slice zrobić drugi cleanup assetów i upstreamowego contentu
  oparty na zależnościach. Nie usuwać ich agresywnie w trakcie budowy pionu.
- README skrócić do Mandate of Three; Tiny MMO zostawić jako upstream/credits
  i referencję infrastruktury.
- Nowa praca trafia na tematyczne branche i jest integrowana lokalnym merge.

## Kolejność po pionie PvE

Aktualna decyzja użytkownika: najpierw **Combat Feel Pass**, dopiero później
**Item Progression Slice**. Nie rozwijamy teraz item/crafting frameworka.

Combat Feel Pass obejmuje kierunkowy hitbox melee, wiele trafionych celów,
trzyciosowe combo z odrzutem finału, kilka Wild Dogów, nawigację mobów,
reakcję na trafienie oraz śmierć i respawn gracza. Zaznaczenie celu jest pomocą
dla autoataku i przyszłych skilli; podstawowy atak nie wymaga zaznaczenia.
Wdrożenie i granice prototypu opisuje [Combat Feel Pass](combat-feel.md).

Po ręcznym potwierdzeniu Combat Feel Pass użytkownik zaakceptował pierwszy
[Item Progression Slice](item-progression.md): porównanie znalezionej broni,
equip i odczuwalna zmiana serwerowych obrażeń, z trwałością po relogu.
Balans mobów i parametrów walki zostawiamy na później. Nie rozszerzamy tego
etapu o upgrade, crafting ani ogólny framework progression.

Kolejny wybrany przez użytkownika etap: [XP i poziomy postaci](character-xp.md).
Wykorzystujemy pola i krzywą PlayerResource, dodajemy autorytatywną nagrodę za
zabójstwo, HUD, level-up i trwałość po relogu. Reguła właściciela nagrody jest
spójna z lootem: największy udział w obrażeniach. Balans pozostaje na później.
Ręczny test pierwszego item progression i XP nadal czeka na użytkownika.

Po review: combat używa minimalnego runtime equipment/stats, XP i level działają
w RAM z dirty checkpointem około 60 s. Rezygnujemy z permanentnych kill receiptów.
Itemy pozostają immediate transactional persistence. Przyszły Yang income ma
runtime wallet z pending delta i osobnym checkpointem; krytyczny spend ma być
atomowy razem ze zmianą ekonomii. Pełny podział: [persistence policy](persistence-policy.md).

## Decyzje świata i następne milestone’y — 2026-10-08

[Design Decisions](Mandate_of_Three_Design_Decisions.pdf) ustala jeden logiczny
świat, transparentne overflow layers dopiero później, spawn regions/regional
pressure, solo i party jako pełnoprawne sposoby gry, samodzielne klasy oraz
podstawowe QoL bez consumable tax. Podane wartości są propozycjami do balansu.

Przyjęta kolejność użytkownika:

1. [Yang wallet](yang-wallet.md), GroundCurrency, mały autoloot bez peta,
   HUD, delta checkpoint i jedna testowa operacja critical spend.
2. Upgrade +0 → +1: Yang + jeden materiał, 100% success, atomowy item/wallet
   commit i odświeżenie runtime stats. Bez failure, downgrade, destruction,
   pity ani scrolli.
3. Jeden reroll affixu: zużycie materiału i mutacja w jednej transakcji.
4. Party vertical slice: invite/accept/leave, wspólna instancja i jawne reguły
   XP oraz loot/contribution. Highest damage pozostaje tymczasową regułą solo.
5. Pierwszy regionalny event: zabójstwa podnoszą pressure, threshold tworzy
   Metin-like obiekt w jednym z kilku punktów; wspólna walka, reward i reset.

Boss, darmowy base dungeon, keyed tiery, klasy/aury, poty/lure, AOI,
local prediction, layering i PostgreSQL są później. Nie rozwijamy obecnie
kolejnego dużego refactoru ani ogólnego frameworka craftingu.
