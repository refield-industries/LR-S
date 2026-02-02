const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const common = b.createModule(.{
        .root_source_file = b.path("common/src/root.zig"),
    });

    const lr_proto_gen = b.addExecutable(.{
        .name = "lr_proto_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("proto/gen/src/main.zig"),
            .optimize = optimize,
            .target = b.graph.host,
        }),
    });

    const compile_proto = b.addRunArtifact(lr_proto_gen);
    compile_proto.expectExitCode(0);
    const pb_generated = compile_proto.captureStdOut(.{ .basename = "beyond_generated.zig" });

    for (proto_files) |file| {
        compile_proto.addFileArg(b.path(file));
    }

    const proto = b.createModule(.{
        .root_source_file = b.path("proto/src/root.zig"),
        .optimize = optimize,
        .target = target,
    });

    proto.addAnonymousImport("beyond_generated", .{ .root_source_file = pb_generated });

    const confsv = b.addExecutable(.{
        .name = "lr-confsv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("confsv/src/main.zig"),
            .imports = &.{.{ .name = "common", .module = common }},
            .target = target,
            .optimize = optimize,
        }),
    });

    const gamesv = b.addExecutable(.{
        .name = "lr-gamesv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("gamesv/src/main.zig"),
            .imports = &.{
                .{ .name = "common", .module = common },
                .{ .name = "proto", .module = proto },
            },
            .target = target,
            .optimize = optimize,
        }),
    });

    gamesv.step.dependOn(&compile_proto.step);

    b.step(
        "run-confsv",
        "run the config server",
    ).dependOn(&b.addRunArtifact(confsv).step);

    b.step(
        "run-gamesv",
        "run the game server",
    ).dependOn(&b.addRunArtifact(gamesv).step);

    b.installArtifact(confsv);
    b.installArtifact(gamesv);
}

const proto_files: []const []const u8 = &.{
    "proto/pb/battle.proto",
    "proto/pb/common.proto",
    "proto/pb/cs_achieve.proto",
    "proto/pb/cs_activity.proto",
    "proto/pb/cs_adventure_book.proto",
    "proto/pb/cs_adventure.proto",
    "proto/pb/cs_anti_cheat.proto",
    "proto/pb/cs_battle.proto",
    "proto/pb/cs_bitset.proto",
    "proto/pb/cs_bp.proto",
    "proto/pb/cs_character.proto",
    "proto/pb/cs_char_bag.proto",
    "proto/pb/cs_collection.proto",
    "proto/pb/cs_dialog.proto",
    "proto/pb/cs_domain_depot.proto",
    "proto/pb/cs_domain_development.proto",
    "proto/pb/cs_doodad_group.proto",
    "proto/pb/cs_dungeon.proto",
    "proto/pb/cs_energy_point.proto",
    "proto/pb/cs_equip.proto",
    "proto/pb/cs_factory_blue_print.proto",
    "proto/pb/cs_factory_chapter.proto",
    "proto/pb/cs_factory_op.proto",
    "proto/pb/cs_factory.proto",
    "proto/pb/cs_focus_mode.proto",
    "proto/pb/cs_friend_chat.proto",
    "proto/pb/cs_friend.proto",
    "proto/pb/cs_gacha.proto",
    "proto/pb/cs_game_mechanics.proto",
    "proto/pb/cs_game_mode.proto",
    "proto/pb/cs_game_var.proto",
    "proto/pb/cs_gem.proto",
    "proto/pb/cs_global_effect.proto",
    "proto/pb/cs_guide.proto",
    "proto/pb/cs_item_bag.proto",
    "proto/pb/cs_kite_station.proto",
    "proto/pb/cs_login.proto",
    "proto/pb/cs_mail.proto",
    "proto/pb/cs_map_mark.proto",
    "proto/pb/cs_mini_game.proto",
    "proto/pb/cs_misc.proto",
    "proto/pb/cs_mission.proto",
    "proto/pb/cs_monster_spawner.proto",
    "proto/pb/cs_monthlycard.proto",
    "proto/pb/cs_msgid.proto",
    "proto/pb/cs_npc.proto",
    "proto/pb/cs_pay.proto",
    "proto/pb/cs_proto.proto",
    "proto/pb/cs_prts.proto",
    "proto/pb/cs_punish.proto",
    "proto/pb/cs_racing_dungeon.proto",
    "proto/pb/cs_recycle_bin.proto",
    "proto/pb/cs_red_dot.proto",
    "proto/pb/cs_scene.proto",
    "proto/pb/cs_sensitive.proto",
    "proto/pb/cs_settlement.proto",
    "proto/pb/cs_shop.proto",
    "proto/pb/cs_sns.proto",
    "proto/pb/cs_spaceship.proto",
    "proto/pb/cs_statistic.proto",
    "proto/pb/cs_submit_item.proto",
    "proto/pb/cs_td.proto",
    "proto/pb/cs_time_freeze.proto",
    "proto/pb/cs_tools.proto",
    "proto/pb/cs_unlock.proto",
    "proto/pb/cs_wallet.proto",
    "proto/pb/cs_weapon.proto",
    "proto/pb/cs_week_raid.proto",
    "proto/pb/cs_wiki.proto",
    "proto/pb/errorcode.proto",
    "proto/pb/factory_core.proto",
    "proto/pb/options.proto",
    "proto/pb/ss_common.proto",
};
