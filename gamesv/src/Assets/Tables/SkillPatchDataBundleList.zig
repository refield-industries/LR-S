pub const file = "SkillPatchTable.json";

SkillPatchDataBundle: []const SkillPatchData,

pub const SkillPatchData = struct {
    coolDown: f32,
    costType: u32,
    costValue: f32,
    level: u32,
    maxChargeTime: u32,
    skillId: []const u8,
};
