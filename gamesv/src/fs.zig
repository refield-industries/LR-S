const std = @import("std");
pub const persistence = @import("fs/persistence.zig");

const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.Crc32;
const MultiArrayList = std.MultiArrayList;

const log = std.log.scoped(.fs);

pub const RepresentationError = error{ReprSizeMismatch};

pub const LoadStructError = error{
    SystemResources,
    FileNotFound,
    InputOutput,
    ChecksumMismatch,
} || RepresentationError || Io.Cancelable;

pub const LoadDynamicArrayError = Allocator.Error || LoadStructError;

pub const SaveStructError = error{
    SystemResources,
    InputOutput,
} || Io.Cancelable;

const struct_header_size: usize = checksum_size;
const checksum_size: usize = 4;

const ArrayHeader = struct {
    checksum: u32,
    item_count: u32,
};

pub fn loadStruct(comptime T: type, io: Io, dir: Dir, sub_path: []const u8) LoadStructError!T {
    const repr_size = @sizeOf(T);
    var result: T = undefined;

    const file = dir.openFile(io, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.SystemResources, error.Canceled => |e| return e,
        else => |e| {
            log.debug("fs.loadStruct('{s}') openFile failed: {t}", .{ sub_path, e });
            return error.SystemResources;
        },
    };

    defer file.close(io);

    const length = file.length(io) catch |err| switch (err) {
        error.Streaming => unreachable,
        error.Canceled, error.SystemResources => |e| return e,
        else => |e| {
            log.debug("fs.loadStruct('{s}') File.length() failed: {t}", .{ sub_path, e });
            return error.SystemResources;
        },
    };

    if (length != repr_size + struct_header_size)
        return RepresentationError.ReprSizeMismatch;

    var file_reader = file.reader(io, "");
    const reader = &file_reader.interface;

    var checksum: [4]u8 = undefined;
    reader.readSliceAll(&checksum) catch |err| switch (err) {
        error.ReadFailed => switch (file_reader.err.?) {
            error.Canceled, error.SystemResources => |e| return e,
            else => return error.InputOutput,
        },
        else => return error.InputOutput,
    };

    const bytes: [*]u8 = @ptrCast(&result);
    var bytes_writer: Io.Writer = .fixed(bytes[0..repr_size]);

    var writer_buf: [128]u8 = undefined; // Just to amortize vtable calls.
    var hashed: Io.Writer.Hashed(Crc32) = .initHasher(&bytes_writer, .init(), &writer_buf);

    reader.streamExact(&hashed.writer, repr_size) catch |err| switch (err) {
        error.ReadFailed => switch (file_reader.err.?) {
            error.Canceled, error.SystemResources => |e| return e,
            else => return error.InputOutput,
        },
        else => return error.InputOutput,
    };

    hashed.writer.flush() catch unreachable;

    if (hashed.hasher.final() != std.mem.readInt(u32, &checksum, .native))
        return error.ChecksumMismatch;

    return result;
}

pub fn saveStruct(comptime T: type, data: *const T, io: Io, dir: Dir, sub_path: []const u8) !void {
    const repr_size = @sizeOf(T);

    const file = dir.createFile(io, sub_path, .{}) catch |err| switch (err) {
        error.Canceled, error.SystemResources => |e| return e,
        else => |e| {
            log.debug("saveStruct('{s}'): createFile failed: {t}", .{ sub_path, e });
            return error.InputOutput;
        },
    };

    defer file.close(io);

    var file_writer_buf: [1024]u8 = undefined;
    var file_writer = file.writer(io, &file_writer_buf);

    // Checksum placeholder.
    file_writer.interface.writeInt(u32, 0, .native) catch return error.InputOutput;

    var hashed_writer_buf: [128]u8 = undefined; // Just to amortize vtable calls.
    var hashed: Io.Writer.Hashed(Crc32) = .initHasher(&file_writer.interface, .init(), &hashed_writer_buf);

    const bytes: [*]const u8 = @ptrCast(data);
    hashed.writer.writeAll(bytes[0..repr_size]) catch return error.InputOutput;
    hashed.writer.flush() catch return error.InputOutput;
    file_writer.seekTo(0) catch return error.InputOutput;

    file_writer.interface.writeInt(u32, hashed.hasher.final(), .native) catch return error.InputOutput;
    file_writer.interface.flush() catch return error.InputOutput;
}

pub fn loadDynamicArray(
    comptime Elem: type,
    io: Io,
    dir: Dir,
    gpa: Allocator,
    sub_path: []const u8,
) LoadDynamicArrayError![]Elem {
    const elem_size = @sizeOf(Elem);
    const file = dir.openFile(io, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.SystemResources, error.Canceled => |e| return e,
        else => |e| {
            log.debug("fs.loadDynamicArray('{s}') openFile failed: {t}", .{ sub_path, e });
            return error.SystemResources;
        },
    };

    defer file.close(io);

    const length = file.length(io) catch |err| switch (err) {
        error.Streaming => unreachable,
        error.Canceled, error.SystemResources => |e| return e,
        else => |e| {
            log.debug("fs.loadDynamicArray('{s}') File.length() failed: {t}", .{ sub_path, e });
            return error.SystemResources;
        },
    };

    if (length < @sizeOf(ArrayHeader))
        return RepresentationError.ReprSizeMismatch;

    var file_reader = file.reader(io, "");
    const reader = &file_reader.interface;

    var header: ArrayHeader = undefined;
    reader.readSliceAll(@ptrCast(&header)) catch |err| switch (err) {
        error.ReadFailed => switch (file_reader.err.?) {
            error.Canceled, error.SystemResources => |e| return e,
            else => return error.InputOutput,
        },
        else => return error.InputOutput,
    };

    if (length < (elem_size * header.item_count) + @sizeOf(ArrayHeader))
        return RepresentationError.ReprSizeMismatch;

    const result = try gpa.alloc(Elem, header.item_count);
    errdefer gpa.free(result);

    const bytes: [*]u8 = @ptrCast(result);
    var bytes_writer: Io.Writer = .fixed(bytes[0 .. elem_size * header.item_count]);

    var writer_buf: [128]u8 = undefined; // Just to amortize vtable calls.
    var hashed: Io.Writer.Hashed(Crc32) = .initHasher(&bytes_writer, .init(), &writer_buf);

    reader.streamExact(&hashed.writer, elem_size * header.item_count) catch |err| switch (err) {
        error.ReadFailed => switch (file_reader.err.?) {
            error.Canceled, error.SystemResources => |e| return e,
            else => return error.InputOutput,
        },
        else => return error.InputOutput,
    };

    hashed.writer.flush() catch unreachable;

    if (hashed.hasher.final() != header.checksum)
        return error.ChecksumMismatch;

    return result;
}

pub fn saveDynamicArray(comptime Elem: type, array: []const Elem, io: Io, dir: Dir, sub_path: []const u8) SaveStructError!void {
    std.debug.assert(array.len <= std.math.maxInt(u32));

    const file = dir.createFile(io, sub_path, .{}) catch |err| switch (err) {
        error.Canceled, error.SystemResources => |e| return e,
        else => |e| {
            log.debug("saveDynamicArray('{s}'): createFile failed: {t}", .{ sub_path, e });
            return error.InputOutput;
        },
    };

    defer file.close(io);

    var file_writer_buf: [1024]u8 = undefined;
    var file_writer = file.writer(io, &file_writer_buf);

    // Checksum placeholder.
    file_writer.interface.writeInt(u32, 0, .native) catch return error.InputOutput;
    file_writer.interface.writeInt(u32, @truncate(array.len), .native) catch return error.InputOutput;

    var hashed_writer_buf: [128]u8 = undefined; // Just to amortize vtable calls.
    var hashed: Io.Writer.Hashed(Crc32) = .initHasher(&file_writer.interface, .init(), &hashed_writer_buf);

    hashed.writer.writeAll(@ptrCast(array)) catch return error.InputOutput;
    hashed.writer.flush() catch return error.InputOutput;
    file_writer.seekTo(0) catch return error.InputOutput;

    file_writer.interface.writeInt(u32, hashed.hasher.final(), .native) catch return error.InputOutput;
    file_writer.interface.flush() catch return error.InputOutput;
}

pub fn loadMultiArrayList(
    comptime Elem: type,
    io: Io,
    dir: Dir,
    gpa: Allocator,
    sub_path: []const u8,
) LoadDynamicArrayError!MultiArrayList(Elem) {
    const file = dir.openFile(io, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.SystemResources, error.Canceled => |e| return e,
        else => |e| {
            log.debug("fs.loadMultiArrayList('{s}') openFile failed: {t}", .{ sub_path, e });
            return error.SystemResources;
        },
    };

    defer file.close(io);

    const length = file.length(io) catch |err| switch (err) {
        error.Streaming => unreachable,
        error.Canceled, error.SystemResources => |e| return e,
        else => |e| {
            log.debug("fs.loadMultiArrayList('{s}') File.length() failed: {t}", .{ sub_path, e });
            return error.SystemResources;
        },
    };

    if (length < @sizeOf(ArrayHeader))
        return RepresentationError.ReprSizeMismatch;

    var file_reader = file.reader(io, "");

    var header: ArrayHeader = undefined;
    file_reader.interface.readSliceAll(@ptrCast(&header)) catch |err| switch (err) {
        error.ReadFailed => switch (file_reader.err.?) {
            error.Canceled, error.SystemResources => |e| return e,
            else => return error.InputOutput,
        },
        else => return error.InputOutput,
    };

    const bytes_length = MultiArrayList(Elem).capacityInBytes(header.item_count);

    if (length < bytes_length + @sizeOf(ArrayHeader))
        return RepresentationError.ReprSizeMismatch;

    var result = try MultiArrayList(Elem).initCapacity(gpa, header.item_count);
    errdefer result.deinit(gpa);
    result.len = header.item_count;

    const fields = comptime std.enums.values(MultiArrayList(Elem).Field);
    var vecs: [fields.len][]u8 = undefined;
    var slice = result.slice();

    inline for (fields) |field| {
        vecs[@intFromEnum(field)] = std.mem.sliceAsBytes(slice.items(field));
    }

    var hashed = file_reader.interface.hashed(Crc32.init(), "");
    hashed.reader.readVecAll(&vecs) catch |err| switch (err) {
        error.ReadFailed => switch (file_reader.err.?) {
            error.Canceled, error.SystemResources => |e| return e,
            else => return error.InputOutput,
        },
        else => return error.InputOutput,
    };

    if (hashed.hasher.final() != header.checksum)
        return error.ChecksumMismatch;

    return result;
}

pub fn saveMultiArrayList(
    comptime Elem: type,
    list: *const MultiArrayList(Elem),
    io: Io,
    dir: Dir,
    sub_path: []const u8,
) SaveStructError!void {
    std.debug.assert(list.len <= std.math.maxInt(u32));

    const file = dir.createFile(io, sub_path, .{}) catch |err| switch (err) {
        error.Canceled, error.SystemResources => |e| return e,
        else => |e| {
            log.debug("saveMultiArrayList('{s}'): createFile failed: {t}", .{ sub_path, e });
            return error.InputOutput;
        },
    };

    defer file.close(io);

    var file_writer_buf: [1024]u8 = undefined;
    var file_writer = file.writer(io, &file_writer_buf);

    // Checksum placeholder.
    file_writer.interface.writeInt(u32, 0, .native) catch return error.InputOutput;
    file_writer.interface.writeInt(u32, @truncate(list.len), .native) catch return error.InputOutput;

    var hashed_writer_buf: [128]u8 = undefined; // Just to amortize vtable calls.
    var hashed: Io.Writer.Hashed(Crc32) = .initHasher(&file_writer.interface, .init(), &hashed_writer_buf);

    const fields = comptime std.enums.values(MultiArrayList(Elem).Field);
    var vecs: [fields.len][]const u8 = undefined;
    var slice = list.slice();

    inline for (fields) |field| {
        vecs[@intFromEnum(field)] = std.mem.sliceAsBytes(slice.items(field));
    }

    hashed.writer.writeVecAll(&vecs) catch return error.InputOutput;
    hashed.writer.flush() catch return error.InputOutput;
    file_writer.seekTo(0) catch return error.InputOutput;

    file_writer.interface.writeInt(u32, hashed.hasher.final(), .native) catch return error.InputOutput;
    file_writer.interface.flush() catch return error.InputOutput;
}
