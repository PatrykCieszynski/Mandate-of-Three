// Wire values match NpcServiceDefinition.Kind. Never infer kinds from labels.
export var NpcServiceKind;
(function (NpcServiceKind) {
    NpcServiceKind[NpcServiceKind["SHOP"] = 0] = "SHOP";
    NpcServiceKind[NpcServiceKind["UPGRADE"] = 1] = "UPGRADE";
    NpcServiceKind[NpcServiceKind["STORAGE"] = 2] = "STORAGE";
    NpcServiceKind[NpcServiceKind["QUEST"] = 3] = "QUEST";
})(NpcServiceKind || (NpcServiceKind = {}));
export function npcOpening(snapshot) {
    if (!snapshot.active)
        return { mode: 'none' };
    const enabled = snapshot.services.filter((service) => service.enabled);
    const selected = enabled.find((service) => service.id === snapshot.selectedServiceId);
    if (selected)
        return { mode: 'service', service: selected };
    if (enabled.length === 1 && enabled[0])
        return { mode: 'select', service: enabled[0] };
    return { mode: enabled.length > 1 ? 'menu' : 'none' };
}
