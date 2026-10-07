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
