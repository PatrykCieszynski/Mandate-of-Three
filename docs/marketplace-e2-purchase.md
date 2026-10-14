# E2: Atomic marketplace purchase

Authenticated market.buy supplies command_id, shop_id, offer_id, expected offer
revision and the displayed whole-stack price. World derives buyer account/character;
no caller-supplied owner or seller is accepted. An active shop, distinct account,
current offer/price and a fitting bag footprint are required before money moves.

One BEGIN IMMEDIATE incorporates both accounts' pending grind income, debits the
buyer, credits the seller, removes occupied shop cells, transfers the existing UID
to buyer bag, removes the live offer and records the result. Seller can be offline.
Runtime wallets change only after COMMIT, and only for a newly committed command.
A receipt replay never reinstalls old balance snapshots over newer RAM income.
Online account peers receive wallet and own-shop refreshes after commit.

market_purchase covers self-account alts, pause/stale, full receiver (zero cost),
every SQL write stage, pending incomes on both sides, offline settlement, reopen
and stale-balance retry. market_race runs two real clients through Web bridge and
RPC: exactly one receives the UID; the other sees unavailable; seller credited once.
Existing smoke contracts pass. Buyer shop presentation is added with E3b search;
this package establishes the explicit purchase path without speculative browsing UI.
