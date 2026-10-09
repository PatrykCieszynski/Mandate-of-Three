# UI follow-up

- The current InventoryStorageTransferController (`screens/storage/inventory-storage-transfer.ts`)
  is transitional and explicitly knows Inventory and Storage. Do not extend it to
  NPC Shop, Player Shop, Trade or Equipment. Before the next system requiring
  cross-window item interaction, design the common drag/drop and item interaction
  rules layer. Do not implement that framework in this cleanup pass.
