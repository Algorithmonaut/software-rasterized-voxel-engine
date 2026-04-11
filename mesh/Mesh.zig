const std = @import("std");
const BlockId = @import("../world/Block.zig").BlockId;

pub const PlaneKind = enum(u8) { pos_x, neg_x, pos_y, neg_y, pos_z, neg_z };

pub const RenderQuad = struct {
    fixed: u8, // fixed coordinate on the normal axis
    row: u8, // first varying coordinate
    col: u8, // second varying coordinate
    width: u8,
    height: u8,
    block_id: BlockId,
};

pub const Mesh = struct {
    pos_x_faces: std.ArrayList(RenderQuad) = .empty,
    neg_x_faces: std.ArrayList(RenderQuad) = .empty,
    pos_y_faces: std.ArrayList(RenderQuad) = .empty,
    neg_y_faces: std.ArrayList(RenderQuad) = .empty,
    pos_z_faces: std.ArrayList(RenderQuad) = .empty,
    neg_z_faces: std.ArrayList(RenderQuad) = .empty,

    pub inline fn appendRenderQuad(
        self: *Mesh,
        allocator: std.mem.Allocator,
        plane_kind: PlaneKind,
        render_quad: RenderQuad,
    ) !void {
        switch (plane_kind) {
            .pos_x => try self.pos_x_faces.append(allocator, render_quad),
            .neg_x => try self.neg_x_faces.append(allocator, render_quad),
            .pos_y => try self.pos_y_faces.append(allocator, render_quad),
            .neg_y => try self.neg_y_faces.append(allocator, render_quad),
            .pos_z => try self.pos_z_faces.append(allocator, render_quad),
            .neg_z => try self.neg_z_faces.append(allocator, render_quad),
        }
    }

    pub inline fn clear(self: *Mesh) void {
        self.pos_x_faces.clearRetainingCapacity();
        self.neg_x_faces.clearRetainingCapacity();
        self.pos_y_faces.clearRetainingCapacity();
        self.neg_y_faces.clearRetainingCapacity();
        self.pos_z_faces.clearRetainingCapacity();
        self.neg_z_faces.clearRetainingCapacity();
    }
};
