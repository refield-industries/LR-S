const logic = @import("../../logic.zig");

pub const file = "CharacterTable.json";

pub const AttributeDataPack = struct {
    Attribute: AttributeData,
    breakStage: i32,
};

pub const AttributeData = struct {
    attrs: []const logic.attrs.AttributePair,
};

attributes: []const AttributeDataPack,
charBattleTagIds: []const []const u8,
charId: []const u8,
mainAttrType: i32,
profession: u32,
rarity: u32,
resilienceDeductionFactor: f32,
sortOrder: u32,
subAttrType: i32,
superArmor: u32,
weaponType: u32,
