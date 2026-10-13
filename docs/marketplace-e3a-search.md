# E3a: Indexed marketplace search

Schema 20 adds item_affix_index (UID, ordinal, stat_id, rolled value), maintained by
insert/update triggers and cascading deletion. Search never parses affixes_json.
Migration backfills existing rolls atomically; a stamp failure rolls everything back.
Definition/upgrade, price/offer and affix indexes bound the public query.

Catalog normalizes case and common European diacritics, returns one base definition
per item and authoritative stat labels/units. The first explicit searchable stats
are attack, attack_speed, monster_damage and critical_chance. These identify rolled
values; they do not add a new combat stat system. Category filters are deferred
until content defines categories. No locale-specific name is used as identity.

Search requires definition_id, inclusive upgrade_min/max, inclusive price_min/max,
up to four distinct affix_filters (AND minimum), price_asc/price_desc, cursor and
limit 1..50. Inverted upgrade bounds are rejected, never swapped. SQL bindings are
used throughout. Price+offer ID keyset ordering avoids offset scans. A cursor is
bounded and validated; mutable market pagination is not a frozen historical snapshot.
Each result includes public item data, shop/offer ID, current revision and price.
visit reads the full shop without exposing claims or account credentials.

Local 10k benchmark: 500 shops x 20 two-cell swords, 100 samples, one SQL query per
search including 50 item snapshots. p50 10.178 ms, p95 17.104 ms; DB-only p50 9.047
ms, p95 15.015 ms. This is a development Windows/disk observation, not capacity/QPS
or production contention evidence. market_search validates catalog, +7..+9,+9..+9,
inverted bounds, rolled AND negatives, cursor, bounds, SQL input, projection mutation,
migration rollback and reopen. Purchase and two-client race regressions still pass.
