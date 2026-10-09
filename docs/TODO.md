# UI follow-up

- ItemDragRuntime v1 replaces the transitional Inventory/Storage controller.
  Future Shop/Trade item subjects and drop rules belong in feature policies;
  do not add feature routing or gameplay commands to the gesture runtime.
- Before Shop work, share authoritative Inventory receiving checks within the
  economic transaction. Capacity failure must not charge the buyer. See the
  [receive/purchase invariants](item-drag-runtime.md#future-purchase-invariant).
