// Application composition: only the changed domain's consumers receive state.
// Input has already passed the protocol and DomainStore runtime validators.
export function updateGameViews(type, state, views) {
    const snapshot = type === 'ui.snapshot';
    const inventoryUpdate = (snapshot || type === 'inventory.updated') && state.inventory !== undefined;
    const equipmentUpdate = snapshot || type === 'equipment.updated';
    let inventoryChanged = false, equipmentChanged = false, inventoryOpened = false, equipmentOpened = false, geometryChanged = false;
    if (snapshot || type === 'hud.updated') {
        const inventoryHidden = !state.hud?.inventory_open, equipmentHidden = !state.hud?.equipment_open;
        inventoryChanged = views.inventoryRoot.hidden !== inventoryHidden;
        equipmentChanged = views.equipmentRoot.hidden !== equipmentHidden;
        inventoryOpened = inventoryChanged && !inventoryHidden;
        equipmentOpened = equipmentChanged && !equipmentHidden;
        views.inventoryRoot.hidden = inventoryHidden;
        views.equipmentRoot.hidden = equipmentHidden;
        const viewport = views.viewport(), scale = state.hud?.ui_scale ?? views.manager.scale;
        geometryChanged =
            viewport.width !== views.manager.viewport.width ||
                viewport.height !== views.manager.viewport.height ||
                scale !== views.manager.scale;
        // Native resize events may lag behind a HUD snapshot.
        views.manager.setViewport(viewport, scale);
    }
    if (inventoryUpdate && state.inventory)
        views.inventory.setState({ ...state, inventory: state.inventory });
    if (equipmentUpdate)
        views.equipment.setState(state);
    if (snapshot || type === 'wallet.updated')
        views.inventory.setInfo(state);
    // Rendering and changed geometry already refresh the affected windows.
    if (inventoryChanged && !inventoryUpdate && !geometryChanged)
        views.inventory.refresh();
    if (equipmentChanged && !equipmentUpdate && !geometryChanged)
        views.equipment.refresh();
    if (inventoryOpened)
        views.inventory.activate();
    if (equipmentOpened)
        views.equipment.activate();
    if (inventoryChanged || equipmentChanged)
        views.onRegionsChanged();
}
