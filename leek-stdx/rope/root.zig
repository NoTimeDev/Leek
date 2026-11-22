//! This module provides rope manipulation
const std = @import("std");
const NODE_STRING_SIZE = 128;
const STEM_SIZE = 16;

pub const Node = union(enum){
    Branch: struct {
        children: [STEM_SIZE]?*Node = @splat(null),
        children_count: usize = 0,
        len: usize = 0,
    },
    Leaf: struct {
        len: usize = 0,
        str: [NODE_STRING_SIZE]u8 = undefined,
    },

    pub fn len(self: *const Node) usize{
        switch (self.*) {
            .Leaf => {
                return self.Leaf.len;
            },
            .Branch => {
                return self.Branch.len; 
            }
        }
    }
};

    
pub const Rope = struct {
    allocator: std.mem.Allocator,
    head: Node,

    pub fn init(allocator: std.mem.Allocator) Rope{
        return .{
            .allocator = allocator,
            .head = .{ .Leaf = .{} }, 
        };
    }

    /// Replaces text with data, if start == end it acts as an insert
    pub fn replace(self: *Rope, indx: struct{start: usize, end: usize}, str: []const u8) !void{
        var current = &self.head;
        var remaing = indx.start;
        while(current.* == .Branch){
            const branch = &current.Branch; 
            for(branch.children[0..branch.children_count])|child|{
                const child_len = child.?.len();
                if(remaing < child_len){
                    current = child.?;
                    break;
                }
                remaing-= child_len;
            }
        }
        std.debug.print("{any}", .{current});
        _ = str;
    }
};
