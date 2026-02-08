const logic = @import("../../logic.zig");

pub const file = "EnemyAttributeTemplateTable.json";

pub const AttributeData = struct {
    attrs: []const logic.attrs.AttributePair,
};

levelDependentAttributes: []const AttributeData,
levelIndependentAttributes: AttributeData,
templateId: []const u8,
