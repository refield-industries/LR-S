pub const file = "CommonSkillConfig.json";

config: struct {
    Character: SkillConfigList,
},

pub const SkillConfigList = struct {
    skillConfigs: []const SkillConfig,
};

pub const SkillConfig = struct {
    skillId: []const u8,
    skillType: u32,
};
