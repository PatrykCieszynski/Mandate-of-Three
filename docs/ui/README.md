# UI and CEF

- [Web UI foundations](web-ui.md), [protocol and layout contract](ui-contract.md), [Core UI](core-ui.md)
- [Character stats and point allocation](../gameplay/character-xp.md) — Character · V, server-authoritative totals and stable allocation retry.
- [Production Inventory](inventory-ui-prototype.md), [drag-and-drop lifecycle](item-drag-runtime.md), [tooltips](item-tooltips.md)
- [CEF installation and export](cef-addon-integration.md)
- [Legacy local UI skin cache](legacy-ui-cache.md) (optional local development aid; candidate to consolidate)

The Godot server owns Inventory, item revisions and wallet state; TypeScript/CEF are presentation and intent only. For tests and build workflow see [development](../development/README.md).
