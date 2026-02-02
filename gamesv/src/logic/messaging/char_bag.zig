const std = @import("std");
const pb = @import("proto").pb;
const logic = @import("../../logic.zig");
const Assets = @import("../../Assets.zig");

const event = logic.event;
const messaging = logic.messaging;
const Player = logic.Player;

pub fn onCharBagSetTeamLeader(
    request: messaging.Request(pb.CS_CHAR_BAG_SET_TEAM_LEADER),
    char_bag: Player.Component(.char_bag),
    team_modified_tx: event.Sender(.char_bag_team_modified),
) !void {
    const log = std.log.scoped(.char_bag_set_team_leader);

    if ((request.message.team_type orelse .CHAR_BAG_TEAM_TYPE_MAIN) != .CHAR_BAG_TEAM_TYPE_MAIN)
        return; // 'TEMP' teams are not supported.

    const team_index = std.math.cast(usize, request.message.team_index) orelse {
        log.err("invalid team index: {d}", .{request.message.team_index});
        return;
    };

    const char_index: Player.CharBag.CharIndex = .fromObjectId(
        request.message.leaderid,
    );

    char_bag.data.ensureTeamMember(team_index, char_index) catch |err| switch (err) {
        error.InvalidTeamIndex => {
            log.err(
                "team index is out of range! {d}/{d}",
                .{ team_index, char_bag.data.teams.len },
            );
            return;
        },
        error.NotTeamMember => {
            log.err(
                "character with index {d} is not a member of team {d}",
                .{ @intFromEnum(char_index), team_index },
            );
            return;
        },
    };

    const leader_index = &char_bag.data.teams.items(.leader_index)[team_index];

    log.info(
        "switching leader for team {d} ({d} -> {d})",
        .{ team_index, leader_index.*, char_index },
    );

    leader_index.* = char_index;

    try team_modified_tx.send(.{
        .team_index = team_index,
        .modification = .set_leader,
    });
}

pub fn onCharBagSetTeam(
    request: messaging.Request(pb.CS_CHAR_BAG_SET_TEAM),
    char_bag: Player.Component(.char_bag),
    team_modified_tx: event.Sender(.char_bag_team_modified),
) !void {
    const log = std.log.scoped(.char_bag_set_team);

    const team_index = std.math.cast(usize, request.message.team_index) orelse {
        log.err("invalid team index: {d}", .{request.message.team_index});
        return;
    };

    if (request.message.char_team.items.len > Player.CharBag.Team.slots_count) {
        log.err(
            "char_team exceeds slots count! {d}/{d}",
            .{ request.message.char_team.items.len, Player.CharBag.Team.slots_count },
        );
        return;
    }

    if (std.mem.findScalar(u64, request.message.char_team.items, request.message.leader_id) == null) {
        log.err("leader_id doesn't present in char_team", .{});
        return;
    }

    var new_char_team: Player.CharBag.Team.SlotArray = @splat(.empty);

    for (request.message.char_team.items, 0..) |char_id, i| {
        if (std.mem.countScalar(u64, request.message.char_team.items, char_id) > 1) {
            log.err("duplicated character id: {d}", .{char_id});
            return;
        }

        const char_index: Player.CharBag.CharIndex = .fromObjectId(char_id);
        if (@intFromEnum(char_index) >= char_bag.data.chars.len) {
            log.err("invalid character object id: {d}", .{char_id});
            return;
        }

        new_char_team[i] = .fromCharIndex(char_index);
    }

    const teams_slice = char_bag.data.teams.slice();
    teams_slice.items(.char_team)[team_index] = new_char_team;
    teams_slice.items(.leader_index)[team_index] = .fromObjectId(request.message.leader_id);

    try team_modified_tx.send(.{
        .team_index = team_index,
        .modification = .set_char_team,
    });

    try request.session.send(pb.SC_CHAR_BAG_SET_TEAM{
        .team_type = .CHAR_BAG_TEAM_TYPE_MAIN,
        .team_index = request.message.team_index,
        .char_team = request.message.char_team,
        .scope_name = 1,
        .leader_id = request.message.leader_id,
    });
}
