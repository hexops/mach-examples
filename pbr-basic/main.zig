const std = @import("std");
const mach = @import("mach");
const gpu = @import("gpu");
const zm = @import("zmath");
const m3d = @import("model3d");
const assets = @import("assets");
const imgui = @import("mach-imgui").MachImgui(mach);

pub const App = @This();

const Vec4 = [4]f32;
const Vec3 = [3]f32;
const Vec2 = [2]f32;
const Mat4 = [4]Vec4;

fn Dimensions2D(comptime T: type) type {
    return struct {
        width: T,
        height: T,
    };
}

const Vertex = extern struct {
    position: Vec3,
    normal: Vec3,
};

const Model = struct {
    vertex_count: u32,
    index_count: u32,
    vertex_buffer: *gpu.Buffer,
    index_buffer: *gpu.Buffer,
};

const Material = struct {
    const Params = extern struct {
        roughness: f32,
        metallic: f32,
        color: Vec3,
    };

    name: []const u8,
    params: Params,
};

/// The imported model contains an array of vectors that are either positions or normals. Due to the fact that
/// we combine positions and normals into our `Vertex` structure, we need to "repack" all the indices so
/// that they reference a contigious array of Vertex value (Containing both the position and normal)
/// VertexIndexer takes the original "sparse" index (As indices to normals are ignored) and returns a unique index for
/// this new packed / contingious space.
const VertexIndexer = struct {
    const null_index: u32 = std.math.maxInt(u32);
    const null_normal = Vec3{
        std.math.floatMax(f32),
        std.math.floatMax(f32),
        std.math.floatMax(f32),
    };

    const Record = struct {
        normal: Vec3,
        next: u32,

        pub inline fn isNull(self: @This()) bool {
            return std.mem.eql(f32, &self.normal, &null_normal); // self.normal0] == std.math.floatMax(f32);
        }
    };

    const Result = struct {
        index: u32,
        new_vertex: bool,
    };

    buffer: []Record,

    /// Map index from sparse -> packed
    /// Sparse indices are used to fast lookup of stored normal values, but
    /// need to be converted to indices that reference a packed buffer of vertices
    index_map: []u32,

    /// Next index outside of the 1:1 mapping range for storing
    /// position -> normal collisions
    next_collision_index: u32,

    /// Next packed index
    next_packed_index: u32,

    pub fn init(allocator: std.mem.Allocator, collision_index_start: u32, capacity: usize) !@This() {
        var result = VertexIndexer{
            .buffer = try allocator.alloc(Record, capacity),
            .index_map = try allocator.alloc(u32, capacity),
            .next_collision_index = collision_index_start,
            .next_packed_index = 0,
        };
        std.mem.set(Record, result.buffer, Record{ .normal = null_normal, .next = null_index });
        return result;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
        allocator.free(self.index_map);
    }

    pub inline fn nextRecord(self: @This(), record: Record) ?Record {
        return if (record.next == null_index) null else self.buffer[record.next];
    }

    pub inline fn indexFor(self: *@This(), sparse_index: u32, normal: Vec3) Result {
        if (self.buffer[sparse_index].isNull()) {
            // New start of chain, reserve a new packed index and add entry to `index_map`
            self.buffer[sparse_index].normal = normal;
            self.index_map[sparse_index] = self.next_packed_index;
            self.next_packed_index += 1;
            return Result{ .index = self.index_map[sparse_index], .new_vertex = true };
        }
        var record_opt: ?Record = self.buffer[sparse_index];
        var current_index: u32 = sparse_index;
        var previous_index: u32 = undefined;
        while (record_opt) |record| {
            if (std.mem.eql(f32, &record.normal, &normal)) {
                // We already have a record for this normal in our chain
                // Return the related packed index and specify that the vertex doesn't
                // need to be re-written to buffer
                return Result{ .index = self.index_map[current_index], .new_vertex = false };
            }
            previous_index = current_index;
            current_index = record.next;
            record_opt = self.nextRecord(record);
        }
        //
        // No match for normal value in our chain
        //  1. Reserve a new sparse index in the "collision" range
        //  2. Reserve new packed index for sparse index
        //  3. Create new record with normal & append to chain
        //
        const packed_index = self.next_packed_index;
        const remapped_sparse_index = self.next_collision_index;
        self.index_map[remapped_sparse_index] = packed_index;
        self.buffer[remapped_sparse_index].normal = normal;
        self.buffer[previous_index].next = remapped_sparse_index;
        self.next_packed_index += 1;
        self.next_collision_index += 1;
        return Result{
            .index = packed_index,
            .new_vertex = true,
        };
    }
};

test "VertexIndexer" {
    const expect = std.testing.expect;
    const allocator = std.testing.allocator;

    const Face = struct {
        position: [3]u16,
        normal: [3]u16,
    };

    const vertices = [_]Vec3{
        Vec3{ 1.0, 0.0, 0.0 }, // 0: Position
        Vec3{ 2.0, 0.0, 0.0 }, // 1: Position
        Vec3{ 3.0, 0.0, 0.0 }, // 2: Position
        Vec3{ 1.0, 0.0, 0.0 }, // 3: Normal
        Vec3{ 4.0, 0.0, 0.0 }, // 4: Position
        Vec3{ 0.0, 1.0, 0.0 }, // 5: Normal
        Vec3{ 5.0, 0.0, 0.0 }, // 6: Position
        Vec3{ 0.0, 0.0, 1.0 }, // 7: Normal
        Vec3{ 1.0, 0.0, 1.0 }, // 8: Normal
        Vec3{ 6.0, 0.0, 0.0 }, // 9: Position
    };

    const faces = [_]Face{
        .{ .position = .{ 0, 4, 2 }, .normal = .{ 7, 5, 3 } },
        .{ .position = .{ 2, 3, 9 }, .normal = .{ 3, 7, 8 } },
        .{ .position = .{ 9, 2, 4 }, .normal = .{ 8, 7, 5 } },
        .{ .position = .{ 2, 6, 1 }, .normal = .{ 3, 5, 7 } },
        .{ .position = .{ 9, 6, 0 }, .normal = .{ 5, 7, 8 } },
    };

    var indexer = try VertexIndexer.init(allocator, vertices.len, faces.len * 3);
    defer indexer.deinit(allocator);

    {
        const face = faces[0];
        const r0 = indexer.indexFor(face.position[0], vertices[face.normal[0]]);
        const r1 = indexer.indexFor(face.position[1], vertices[face.normal[1]]);
        const r2 = indexer.indexFor(face.position[2], vertices[face.normal[2]]);

        try expect(r0.index == 0); // (0, 7) New
        try expect(r1.index == 1); // (4, 5) New
        try expect(r2.index == 2); // (2, 3) New

        try expect(r0.new_vertex == true);
        try expect(r1.new_vertex == true);
        try expect(r2.new_vertex == true);
    }
    {
        const face = faces[1];
        const r0 = indexer.indexFor(face.position[0], vertices[face.normal[0]]);
        const r1 = indexer.indexFor(face.position[1], vertices[face.normal[1]]);
        const r2 = indexer.indexFor(face.position[2], vertices[face.normal[2]]);

        try expect(r0.index == 2); // (2, 3) Duplicate - Reuse index
        try expect(r1.index == 3); // (3, 7) New
        try expect(r2.index == 4); // (9, 8) New

        try expect(r0.new_vertex == false);
        try expect(r1.new_vertex == true);
        try expect(r2.new_vertex == true);
    }
    {
        const face = faces[2];
        const r0 = indexer.indexFor(face.position[0], vertices[face.normal[0]]);
        const r1 = indexer.indexFor(face.position[1], vertices[face.normal[1]]);
        const r2 = indexer.indexFor(face.position[2], vertices[face.normal[2]]);

        try expect(r0.index == 4); // (9, 8) Duplicate - Reuse index
        try expect(r1.index == 5); // (2, 7) New normal mapping (Don't clobber)
        try expect(r2.index == 1); // (4, 5) Duplicate - Reuse Index

        try expect(r0.new_vertex == false);
        try expect(r1.new_vertex == true);
        try expect(r2.new_vertex == false);
    }

    {
        const face = faces[3];
        const r0 = indexer.indexFor(face.position[0], vertices[face.normal[0]]);
        const r1 = indexer.indexFor(face.position[1], vertices[face.normal[1]]);
        const r2 = indexer.indexFor(face.position[2], vertices[face.normal[2]]);

        try expect(r0.index == 2); // (2, 3) Duplicate - Reuse index
        try expect(r1.index == 6); // (6, 5) New
        try expect(r2.index == 7); // (1, 7) New

        try expect(r0.new_vertex == false);
        try expect(r1.new_vertex == true);
        try expect(r2.new_vertex == true);
    }
    {
        const face = faces[4];
        const r0 = indexer.indexFor(face.position[0], vertices[face.normal[0]]);
        const r1 = indexer.indexFor(face.position[1], vertices[face.normal[1]]);
        const r2 = indexer.indexFor(face.position[2], vertices[face.normal[2]]);

        try expect(r0.index == 8); // (9, 5) New normal mapping (Don't clobber)
        try expect(r1.index == 9); // (6, 7) New normal mapping (Don't clobber)
        try expect(r2.index == 10); // (0, 8) New normal mapping (Don't clobber)

        try expect(r0.new_vertex == true);
        try expect(r1.new_vertex == true);
        try expect(r2.new_vertex == true);
    }
    try expect(indexer.next_packed_index == 11);
}

const PressedKeys = packed struct(u16) {
    right: bool = false,
    left: bool = false,
    up: bool = false,
    down: bool = false,
    padding: u12 = undefined,

    pub inline fn areKeysPressed(self: @This()) bool {
        return (self.up or self.down or self.left or self.right);
    }

    pub inline fn clear(self: *@This()) void {
        self.right = false;
        self.left = false;
        self.up = false;
        self.down = false;
    }
};

const Camera = struct {
    const Matrices = struct {
        perspective: Mat4 = [1]Vec4{[1]f32{0.0} ** 4} ** 4,
        view: Mat4 = [1]Vec4{[1]f32{0.0} ** 4} ** 4,
    };

    rotation: Vec3 = .{ 0.0, 0.0, 0.0 },
    position: Vec3 = .{ 0.0, 0.0, 0.0 },
    view_position: Vec4 = .{ 0.0, 0.0, 0.0, 0.0 },
    fov: f32 = 0.0,
    znear: f32 = 0.0,
    zfar: f32 = 0.0,
    rotation_speed: f32 = 0.0,
    movement_speed: f32 = 0.0,
    updated: bool = false,
    matrices: Matrices = .{},

    pub fn calculateMovement(self: *@This(), pressed_keys: PressedKeys) void {
        std.debug.assert(pressed_keys.areKeysPressed());
        const rotation_radians = Vec3{
            toRadians(self.rotation[0]),
            toRadians(self.rotation[1]),
            toRadians(self.rotation[2]),
        };
        var camera_front = zm.Vec{ -zm.cos(rotation_radians[0]) * zm.sin(rotation_radians[1]), zm.sin(rotation_radians[0]), zm.cos(rotation_radians[0]) * zm.cos(rotation_radians[1]), 0 };
        camera_front = zm.normalize3(camera_front);
        if (pressed_keys.up) {
            camera_front[0] *= self.movement_speed;
            camera_front[1] *= self.movement_speed;
            camera_front[2] *= self.movement_speed;
            self.position = Vec3{
                self.position[0] + camera_front[0],
                self.position[1] + camera_front[1],
                self.position[2] + camera_front[2],
            };
        }
        if (pressed_keys.down) {
            camera_front[0] *= self.movement_speed;
            camera_front[1] *= self.movement_speed;
            camera_front[2] *= self.movement_speed;
            self.position = Vec3{
                self.position[0] - camera_front[0],
                self.position[1] - camera_front[1],
                self.position[2] - camera_front[2],
            };
        }
        if (pressed_keys.right) {
            camera_front = zm.cross3(.{ 0.0, 1.0, 0.0, 0.0 }, camera_front);
            camera_front = zm.normalize3(camera_front);
            camera_front[0] *= self.movement_speed;
            camera_front[1] *= self.movement_speed;
            camera_front[2] *= self.movement_speed;
            self.position = Vec3{
                self.position[0] - camera_front[0],
                self.position[1] - camera_front[1],
                self.position[2] - camera_front[2],
            };
        }
        if (pressed_keys.left) {
            camera_front = zm.cross3(.{ 0.0, 1.0, 0.0, 0.0 }, camera_front);
            camera_front = zm.normalize3(camera_front);
            camera_front[0] *= self.movement_speed;
            camera_front[1] *= self.movement_speed;
            camera_front[2] *= self.movement_speed;
            self.position = Vec3{
                self.position[0] + camera_front[0],
                self.position[1] + camera_front[1],
                self.position[2] + camera_front[2],
            };
        }
        self.updateViewMatrix();
    }

    fn updateViewMatrix(self: *@This()) void {
        const rotation_x = zm.rotationX(toRadians(self.rotation[2]));
        const rotation_y = zm.rotationY(toRadians(self.rotation[1]));
        const rotation_z = zm.rotationZ(toRadians(self.rotation[0]));
        const rotation_matrix = zm.mul(rotation_z, zm.mul(rotation_x, rotation_y));

        const translation_matrix: zm.Mat = zm.translationV(.{
            self.position[0],
            self.position[1],
            self.position[2],
            0,
        });
        const view = zm.mul(translation_matrix, rotation_matrix);
        self.matrices.view[0] = view[0];
        self.matrices.view[1] = view[1];
        self.matrices.view[2] = view[2];
        self.matrices.view[3] = view[3];
        self.view_position = .{
            -self.position[0],
            self.position[1],
            -self.position[2],
            0.0,
        };
        self.updated = true;
    }

    pub fn setMovementSpeed(self: *@This(), speed: f32) void {
        self.movement_speed = speed;
    }

    pub fn setPerspective(self: *@This(), fov: f32, aspect: f32, znear: f32, zfar: f32) void {
        self.fov = fov;
        self.znear = znear;
        self.zfar = zfar;
        const perspective = zm.perspectiveFovRhGl(toRadians(fov), aspect, znear, zfar);
        self.matrices.perspective[0] = perspective[0];
        self.matrices.perspective[1] = perspective[1];
        self.matrices.perspective[2] = perspective[2];
        self.matrices.perspective[3] = perspective[3];
    }

    pub fn setRotationSpeed(self: *@This(), speed: f32) void {
        self.rotation_speed = speed;
    }

    pub fn setRotation(self: *@This(), rotation: Vec3) void {
        self.rotation = rotation;
        self.updateViewMatrix();
    }

    pub fn setPosition(self: *@This(), position: Vec3) void {
        self.position = .{
            position[0],
            -position[1],
            position[2],
        };
        self.updateViewMatrix();
    }
};

const UniformBuffers = struct {
    const Params = struct {
        buffer: *gpu.Buffer,
        buffer_size: u64,
        model_size: u64,
    };
    const Buffer = struct {
        buffer: *gpu.Buffer,
        size: u32,
    };
    ubo_matrices: Buffer,
    ubo_params: Buffer,
    material_params: Params,
    object_params: Params,
};

const UboParams = struct {
    lights: [4]Vec4,
};

const UboMatrices = extern struct {
    projection: Mat4,
    model: Mat4,
    view: Mat4,
    camera_position: Vec3,
};

const grid_element_count = grid_dimensions * grid_dimensions;

const MaterialParamsDynamic = extern struct {
    roughness: f32 = 0,
    metallic: f32 = 0,
    color: Vec3 = .{ 0, 0, 0 },
    padding: [236]u8 = [1]u8{0} ** 236,
};
const MaterialParamsDynamicGrid = [grid_element_count]MaterialParamsDynamic;

const ObjectParamsDynamic = extern struct {
    position: Vec3 = .{ 0, 0, 0 },
    padding: [244]u8 = [1]u8{0} ** 244,
};
const ObjectParamsDynamicGrid = [grid_element_count]ObjectParamsDynamic;

//
// Globals
//

const material_names = [11][:0]const u8{
    "Gold",  "Copper", "Chromium", "Nickel", "Titanium", "Cobalt", "Platinum",
    // Testing materials
    "White", "Red",    "Blue",     "Black",
};

const object_names = [4][:0]const u8{
    "Sphere", "Teapot", "Torusknot", "Venus",
};

const materials = [_]Material{
    .{ .name = "Gold", .params = .{ .roughness = 0.1, .metallic = 1.0, .color = .{ 1.0, 0.765557, 0.336057 } } },
    .{ .name = "Copper", .params = .{ .roughness = 0.1, .metallic = 1.0, .color = .{ 0.955008, 0.637427, 0.538163 } } },
    .{ .name = "Chromium", .params = .{ .roughness = 0.1, .metallic = 1.0, .color = .{ 0.549585, 0.556114, 0.554256 } } },
    .{ .name = "Nickel", .params = .{ .roughness = 0.1, .metallic = 1.0, .color = .{ 1.0, 0.608679, 0.525649 } } },
    .{ .name = "Titanium", .params = .{ .roughness = 0.1, .metallic = 1.0, .color = .{ 0.541931, 0.496791, 0.449419 } } },
    .{ .name = "Cobalt", .params = .{ .roughness = 0.1, .metallic = 1.0, .color = .{ 0.662124, 0.654864, 0.633732 } } },
    .{ .name = "Platinum", .params = .{ .roughness = 0.1, .metallic = 1.0, .color = .{ 0.672411, 0.637331, 0.585456 } } },
    // Testing colors
    .{ .name = "White", .params = .{ .roughness = 0.1, .metallic = 1.0, .color = .{ 1.0, 1.0, 1.0 } } },
    .{ .name = "Red", .params = .{ .roughness = 0.1, .metallic = 1.0, .color = .{ 1.0, 0.0, 0.0 } } },
    .{ .name = "Blue", .params = .{ .roughness = 0.1, .metallic = 1.0, .color = .{ 0.0, 0.0, 1.0 } } },
    .{ .name = "Black", .params = .{ .roughness = 0.1, .metallic = 1.0, .color = .{ 0.0, 0.0, 0.0 } } },
};

const grid_dimensions = 7;
const model_paths = [_][]const u8{
    assets.sphere_path,
    assets.teapot_path,
    assets.torusknot_path,
    assets.venus_path,
};

//
// Member variables
//

camera: Camera,
render_pipeline: *gpu.RenderPipeline,
render_pass_descriptor: gpu.RenderPassDescriptor,
bind_group: *gpu.BindGroup,
queue: *gpu.Queue,
color_attachment: gpu.RenderPassColorAttachment,
depth_stencil_attachment_description: gpu.RenderPassDepthStencilAttachment,
depth_texture: *gpu.Texture,
depth_texture_view: *gpu.TextureView,
timer: mach.Timer,
pressed_keys: PressedKeys,
models: [4]Model,
ubo_params: UboParams,
ubo_matrices: UboMatrices,
uniform_buffers: UniformBuffers,
material_params_dynamic: MaterialParamsDynamicGrid = [1]MaterialParamsDynamic{.{}} ** grid_element_count,
object_params_dynamic: ObjectParamsDynamicGrid = [1]ObjectParamsDynamic{.{}} ** grid_element_count,
uniform_buffers_dirty: bool,
buffers_bound: bool,
is_paused: bool,
current_material_index: usize,
current_object_index: usize,
imgui_render_pipeline: *gpu.RenderPipeline,

//
// Functions
//

pub fn init(app: *App, core: *mach.Core) !void {
    app.timer = try mach.Timer.start();

    app.queue = core.device.getQueue();
    app.current_material_index = 0;
    app.buffers_bound = false;
    app.uniform_buffers_dirty = false;

    setupCamera(app, core);
    try loadModels(std.heap.c_allocator, app, core);
    prepareUniformBuffers(app, core);
    setupPipeline(app, core);
    setupRenderPass(app, core);
    setupImgui(app, core);
}

pub fn deinit(app: *App, _: *mach.Core) void {
    app.bind_group.release();
    app.render_pipeline.release();
    app.depth_texture_view.release();
    app.depth_texture.release();
    app.uniform_buffers.ubo_matrices.buffer.release();
    app.uniform_buffers.ubo_params.buffer.release();
    app.uniform_buffers.material_params.buffer.release();
    app.uniform_buffers.object_params.buffer.release();
    imgui.backend.deinit();
}

pub fn update(app: *App, core: *mach.Core) !void {
    while (core.pollEvent()) |event| {
        imgui.backend.passEvent(event);
        switch (event) {
            .key_press => |ev| {
                const key = ev.key;
                if (key == .up or key == .w) app.pressed_keys.up = true;
                if (key == .down or key == .s) app.pressed_keys.down = true;
                if (key == .left or key == .a) app.pressed_keys.left = true;
                if (key == .right or key == .d) app.pressed_keys.right = true;
            },
            else => {},
        }
    }
    if (app.pressed_keys.areKeysPressed()) {
        app.camera.calculateMovement(app.pressed_keys);
        app.pressed_keys.clear();
        app.uniform_buffers_dirty = true;
    }

    if (app.uniform_buffers_dirty) {
        updateUniformBuffers(app);
        app.uniform_buffers_dirty = false;
    }

    const back_buffer_view = core.swap_chain.?.getCurrentTextureView();
    app.color_attachment.view = back_buffer_view;
    app.render_pass_descriptor = gpu.RenderPassDescriptor{
        .color_attachment_count = 1,
        .color_attachments = &[_]gpu.RenderPassColorAttachment{app.color_attachment},
        .depth_stencil_attachment = &app.depth_stencil_attachment_description,
    };
    const encoder = core.device.createCommandEncoder(null);
    const current_model = app.models[app.current_object_index];

    const pass = encoder.beginRenderPass(&app.render_pass_descriptor);

    const dimensions = Dimensions2D(f32){
        .width = @intToFloat(f32, core.current_desc.width),
        .height = @intToFloat(f32, core.current_desc.height),
    };
    pass.setViewport(
        0,
        0,
        dimensions.width,
        dimensions.height,
        0.0,
        1.0,
    );
    pass.setScissorRect(0, 0, core.current_desc.width, core.current_desc.height);
    pass.setPipeline(app.render_pipeline);

    if (!app.is_paused) {
        app.updateLights();
    }

    var i: usize = 0;
    while (i < (grid_dimensions * grid_dimensions)) : (i += 1) {
        const alignment = 256;
        const dynamic_offset: u32 = @intCast(u32, i) * alignment;
        const dynamic_offsets = [2]u32{ dynamic_offset, dynamic_offset };
        pass.setBindGroup(0, app.bind_group, &dynamic_offsets);
        if (!app.buffers_bound) {
            pass.setVertexBuffer(0, current_model.vertex_buffer, 0, @sizeOf(Vertex) * current_model.vertex_count);
            pass.setIndexBuffer(current_model.index_buffer, .uint32, 0, gpu.whole_size);
            app.buffers_bound = true;
        }
        pass.drawIndexed(
            current_model.index_count, // index_count
            1, // instance_count
            0, // first_index
            0, // base_vertex
            0, // first_instance
        );
    }

    pass.setPipeline(app.imgui_render_pipeline);

    const window_size = core.getWindowSize();
    imgui.backend.newFrame(
        core,
        window_size.width,
        window_size.height,
    );

    drawUI(app);
    imgui.backend.draw(pass);

    pass.end();
    pass.release();

    var command = encoder.finish(null);
    encoder.release();

    app.queue.submit(&[_]*gpu.CommandBuffer{command});

    command.release();
    core.swap_chain.?.present();
    back_buffer_view.release();
    app.buffers_bound = false;
}

pub fn resize(app: *App, core: *mach.Core, width: u32, height: u32) !void {
    app.depth_texture_view.release();
    app.depth_texture.release();
    app.depth_texture = core.device.createTexture(&gpu.Texture.Descriptor{
        .usage = .{ .render_attachment = true },
        .format = .depth24_plus_stencil8,
        .sample_count = 1,
        .size = .{
            .width = width,
            .height = height,
            .depth_or_array_layers = 1,
        },
    });
    app.depth_texture_view = app.depth_texture.createView(&gpu.TextureView.Descriptor{
        .format = .depth24_plus_stencil8,
        .dimension = .dimension_2d,
        .array_layer_count = 1,
        .aspect = .all,
    });
    app.depth_stencil_attachment_description = gpu.RenderPassDepthStencilAttachment{
        .view = app.depth_texture_view,
        .depth_load_op = .clear,
        .depth_store_op = .store,
        .depth_clear_value = 1.0,
        .clear_stencil = 0,
        .stencil_load_op = .clear,
        .stencil_store_op = .store,
    };

    const aspect_ratio = @intToFloat(f32, width) / @intToFloat(f32, height);
    app.camera.setPerspective(60.0, aspect_ratio, 0.1, 256.0);
    app.uniform_buffers_dirty = true;
}

fn prepareUniformBuffers(app: *App, core: *mach.Core) void {
    comptime {
        std.debug.assert(@sizeOf(ObjectParamsDynamic) == 256);
        std.debug.assert(@sizeOf(MaterialParamsDynamic) == 256);
    }

    app.uniform_buffers.ubo_matrices.size = roundToMultipleOf4(u32, @intCast(u32, @sizeOf(UboMatrices)));
    app.uniform_buffers.ubo_matrices.buffer = core.device.createBuffer(&.{
        .usage = .{ .copy_dst = true, .uniform = true },
        .size = app.uniform_buffers.ubo_matrices.size,
        .mapped_at_creation = false,
    });

    app.uniform_buffers.ubo_params.size = roundToMultipleOf4(u32, @intCast(u32, @sizeOf(UboParams)));
    app.uniform_buffers.ubo_params.buffer = core.device.createBuffer(&.{
        .usage = .{ .copy_dst = true, .uniform = true },
        .size = app.uniform_buffers.ubo_params.size,
        .mapped_at_creation = false,
    });

    //
    // Material parameter uniform buffer
    //
    app.uniform_buffers.material_params.model_size = @sizeOf(Vec2) + @sizeOf(Vec3);
    app.uniform_buffers.material_params.buffer_size = calculateConstantBufferByteSize(@sizeOf(MaterialParamsDynamicGrid));
    std.debug.assert(app.uniform_buffers.material_params.buffer_size >= app.uniform_buffers.material_params.model_size);
    app.uniform_buffers.material_params.buffer = core.device.createBuffer(&.{
        .usage = .{ .copy_dst = true, .uniform = true },
        .size = app.uniform_buffers.material_params.buffer_size,
        .mapped_at_creation = false,
    });

    //
    // Object parameter uniform buffer
    //
    app.uniform_buffers.object_params.model_size = @sizeOf(Vec3);
    app.uniform_buffers.object_params.buffer_size = calculateConstantBufferByteSize(@sizeOf(MaterialParamsDynamicGrid));
    std.debug.assert(app.uniform_buffers.object_params.buffer_size >= app.uniform_buffers.object_params.model_size);
    app.uniform_buffers.object_params.buffer = core.device.createBuffer(&.{
        .usage = .{ .copy_dst = true, .uniform = true },
        .size = app.uniform_buffers.object_params.buffer_size,
        .mapped_at_creation = false,
    });

    app.updateUniformBuffers();
    app.updateDynamicUniformBuffer();
    app.updateLights();
}

fn updateDynamicUniformBuffer(app: *App) void {
    var index: u32 = 0;
    var y: usize = 0;
    while (y < grid_dimensions) : (y += 1) {
        var x: usize = 0;
        while (x < grid_dimensions) : (x += 1) {
            const grid_dimensions_float = @intToFloat(f32, grid_dimensions);
            app.object_params_dynamic[index].position[0] = (@intToFloat(f32, x) - (grid_dimensions_float / 2) * 2.5);
            app.object_params_dynamic[index].position[1] = 0;
            app.object_params_dynamic[index].position[2] = (@intToFloat(f32, y) - (grid_dimensions_float / 2) * 2.5);
            app.material_params_dynamic[index].metallic = zm.clamp(@intToFloat(f32, x) / (grid_dimensions_float - 1), 0.1, 1.0);
            app.material_params_dynamic[index].roughness = zm.clamp(@intToFloat(f32, y) / (grid_dimensions_float - 1), 0.05, 1.0);
            app.material_params_dynamic[index].color = materials[app.current_material_index].params.color;
            index += 1;
        }
    }
    app.queue.writeBuffer(
        app.uniform_buffers.object_params.buffer,
        0,
        &app.object_params_dynamic,
    );
    app.queue.writeBuffer(
        app.uniform_buffers.material_params.buffer,
        0,
        &app.material_params_dynamic,
    );
}

fn updateUniformBuffers(app: *App) void {
    app.ubo_matrices.projection = app.camera.matrices.perspective;
    app.ubo_matrices.view = app.camera.matrices.view;
    const rotation_degrees = if (app.current_object_index == 1) @as(f32, -45.0) else @as(f32, -90.0);
    const model = zm.rotationY(rotation_degrees);
    zm.storeArr4(&app.ubo_matrices.model[0], model[0]);
    zm.storeArr4(&app.ubo_matrices.model[1], model[1]);
    zm.storeArr4(&app.ubo_matrices.model[2], model[2]);
    zm.storeArr4(&app.ubo_matrices.model[3], model[3]);
    app.ubo_matrices.camera_position = .{
        -app.camera.position[0],
        -app.camera.position[1],
        -app.camera.position[2],
    };
    app.queue.writeBuffer(app.uniform_buffers.ubo_matrices.buffer, 0, &[_]UboMatrices{app.ubo_matrices});
}

fn updateLights(app: *App) void {
    const p: f32 = 15.0;
    app.ubo_params.lights[0] = Vec4{ -p, -p * 0.5, -p, 1.0 };
    app.ubo_params.lights[1] = Vec4{ -p, -p * 0.5, p, 1.0 };
    app.ubo_params.lights[2] = Vec4{ p, -p * 0.5, p, 1.0 };
    app.ubo_params.lights[3] = Vec4{ p, -p * 0.5, -p, 1.0 };
    const base_value = toRadians(@mod(app.timer.read() * 0.1, 1.0) * 360.0);
    app.ubo_params.lights[0][0] = @sin(base_value) * 20.0;
    app.ubo_params.lights[0][2] = @cos(base_value) * 20.0;
    app.ubo_params.lights[1][0] = @cos(base_value) * 20.0;
    app.ubo_params.lights[1][1] = @sin(base_value) * 20.0;
    app.queue.writeBuffer(
        app.uniform_buffers.ubo_params.buffer,
        0,
        &[_]UboParams{app.ubo_params},
    );
}

fn setupPipeline(app: *App, core: *mach.Core) void {
    comptime {
        std.debug.assert(@sizeOf(Vertex) == @sizeOf(f32) * 6);
    }

    const bind_group_layout_entries = [_]gpu.BindGroupLayout.Entry{
        .{
            .binding = 0,
            .visibility = .{ .vertex = true, .fragment = true },
            .buffer = .{
                .@"type" = .uniform,
                .has_dynamic_offset = false,
                .min_binding_size = app.uniform_buffers.ubo_matrices.size,
            },
        },
        .{
            .binding = 1,
            .visibility = .{ .fragment = true },
            .buffer = .{
                .@"type" = .uniform,
                .has_dynamic_offset = false,
                .min_binding_size = app.uniform_buffers.ubo_params.size,
            },
        },
        .{
            .binding = 2,
            .visibility = .{ .fragment = true },
            .buffer = .{
                .@"type" = .uniform,
                .has_dynamic_offset = true,
                .min_binding_size = app.uniform_buffers.material_params.model_size,
            },
        },
        .{
            .binding = 3,
            .visibility = .{ .vertex = true },
            .buffer = .{
                .@"type" = .uniform,
                .has_dynamic_offset = true,
                .min_binding_size = app.uniform_buffers.object_params.model_size,
            },
        },
    };

    const bind_group_layout = core.device.createBindGroupLayout(
        &gpu.BindGroupLayout.Descriptor.init(.{
            .entries = bind_group_layout_entries[0..],
        }),
    );

    const bind_group_layouts = [_]*gpu.BindGroupLayout{bind_group_layout};
    const pipeline_layout = core.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
        .bind_group_layouts = &bind_group_layouts,
    }));

    const vertex_buffer_layout = gpu.VertexBufferLayout.init(.{
        .array_stride = @sizeOf(Vertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = @offsetOf(Vertex, "position"), .shader_location = 0 },
            .{ .format = .float32x3, .offset = @offsetOf(Vertex, "normal"), .shader_location = 1 },
        },
    });

    const blend_component_descriptor = gpu.BlendComponent{
        .operation = .add,
        .src_factor = .one,
        .dst_factor = .zero,
    };

    const color_target_state = gpu.ColorTargetState{
        .format = core.swap_chain_format,
        .blend = &.{
            .color = blend_component_descriptor,
            .alpha = blend_component_descriptor,
        },
    };

    const shader_module = core.device.createShaderModuleWGSL("shader.wgsl", @embedFile("shader.wgsl"));
    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .layout = pipeline_layout,
        .primitive = .{
            .cull_mode = .back,
        },
        .depth_stencil = &.{
            .format = .depth24_plus_stencil8,
            .depth_write_enabled = true,
        },
        .fragment = &gpu.FragmentState.init(.{
            .module = shader_module,
            .entry_point = "frag_main",
            .targets = &.{color_target_state},
        }),
        .vertex = gpu.VertexState.init(.{
            .module = shader_module,
            .entry_point = "vertex_main",
            .buffers = &.{vertex_buffer_layout},
        }),
    };
    app.render_pipeline = core.device.createRenderPipeline(&pipeline_descriptor);
    shader_module.release();

    {
        const bind_group_entries = [_]gpu.BindGroup.Entry{
            .{
                .binding = 0,
                .buffer = app.uniform_buffers.ubo_matrices.buffer,
                .size = app.uniform_buffers.ubo_matrices.size,
            },
            .{
                .binding = 1,
                .buffer = app.uniform_buffers.ubo_params.buffer,
                .size = app.uniform_buffers.ubo_params.size,
            },
            .{
                .binding = 2,
                .buffer = app.uniform_buffers.material_params.buffer,
                .size = app.uniform_buffers.material_params.model_size,
            },
            .{
                .binding = 3,
                .buffer = app.uniform_buffers.object_params.buffer,
                .size = app.uniform_buffers.object_params.model_size,
            },
        };
        app.bind_group = core.device.createBindGroup(
            &gpu.BindGroup.Descriptor.init(.{
                .layout = bind_group_layout,
                .entries = &bind_group_entries,
            }),
        );
    }
}

fn setupRenderPass(app: *App, core: *mach.Core) void {
    app.color_attachment = gpu.RenderPassColorAttachment{
        .clear_value = .{
            .r = 0.0,
            .g = 0.0,
            .b = 0.0,
            .a = 0.0,
        },
        .load_op = .clear,
        .store_op = .store,
    };

    app.depth_texture = core.device.createTexture(&.{
        .usage = .{ .render_attachment = true, .copy_src = true },
        .format = .depth24_plus_stencil8,
        .sample_count = 1,
        .size = .{
            .width = core.current_desc.width,
            .height = core.current_desc.height,
            .depth_or_array_layers = 1,
        },
    });

    app.depth_texture_view = app.depth_texture.createView(&.{
        .format = .depth24_plus_stencil8,
        .dimension = .dimension_2d,
        .array_layer_count = 1,
        .aspect = .all,
    });

    app.depth_stencil_attachment_description = gpu.RenderPassDepthStencilAttachment{
        .view = app.depth_texture_view,
        .depth_load_op = .clear,
        .depth_store_op = .store,
        .depth_clear_value = 1.0,
        .clear_stencil = 0,
        .stencil_load_op = .clear,
        .stencil_store_op = .store,
    };
}

fn loadModels(allocator: std.mem.Allocator, app: *App, core: *mach.Core) !void {
    for (model_paths) |model_path, model_path_i| {
        var model_file = std.fs.openFileAbsolute(model_path, .{}) catch |err| {
            std.log.err("Failed to load model: '{s}' Error: {}", .{ model_path, err });
            return error.LoadModelFileFailed;
        };
        defer model_file.close();

        var model_data = try model_file.readToEndAllocOptions(allocator, 4048 * 1024, 4048 * 1024, @alignOf(u8), 0);
        defer allocator.free(model_data);

        const m3d_model = m3d.load(model_data, null, null, null) orelse return error.LoadModelFailed;

        const vertex_count = m3d_model.handle.numvertex;
        const face_count = m3d_model.handle.numface;

        var model: *Model = &app.models[model_path_i];

        model.index_count = face_count * 3;

        var indices_buffer = try allocator.alloc(u32, model.index_count);
        var vertices_buffer = try allocator.alloc(Vertex, face_count * 3);
        defer allocator.free(indices_buffer);
        defer allocator.free(vertices_buffer);

        var vertex_indexer = try VertexIndexer.init(allocator, vertex_count, face_count * 2);
        defer vertex_indexer.deinit(allocator);

        const scale: f32 = 0.45;
        const vertices = m3d_model.handle.vertex[0..vertex_count];
        var i: usize = 0;
        while (i < face_count) : (i += 1) {
            const face = m3d_model.handle.face[i];
            const src_base_index: usize = (i * 3);
            var x: usize = 0;
            while (x < 3) : (x += 1) {
                const vertex_index = face.vertex[x];
                const normal_index = face.normal[x];
                var vertex = Vertex{
                    .position = undefined,
                    .normal = .{
                        vertices[normal_index].x,
                        vertices[normal_index].y,
                        vertices[normal_index].z,
                    },
                };
                const result = vertex_indexer.indexFor(vertex_index, vertex.normal);
                indices_buffer[src_base_index + x] = result.index;
                if (result.new_vertex) {
                    vertex.position = .{
                        vertices[vertex_index].x * scale,
                        vertices[vertex_index].y * scale,
                        vertices[vertex_index].z * scale,
                    };
                    vertices_buffer[result.index] = vertex;
                }
            }
        }
        model.vertex_count = vertex_indexer.next_packed_index;

        model.vertex_buffer = core.device.createBuffer(&.{
            .usage = .{ .copy_dst = true, .vertex = true },
            .size = @sizeOf(Vertex) * model.vertex_count,
            .mapped_at_creation = false,
        });
        app.queue.writeBuffer(
            model.vertex_buffer,
            0,
            vertices_buffer[0..model.vertex_count],
        );

        model.index_buffer = core.device.createBuffer(&.{
            .usage = .{ .copy_dst = true, .index = true },
            .size = @sizeOf(u32) * model.index_count,
            .mapped_at_creation = false,
        });
        app.queue.writeBuffer(
            model.index_buffer,
            0,
            indices_buffer,
        );
    }
}

fn drawUI(app: *App) void {
    imgui.setNextWindowPos(.{ .x = 0, .y = 0 });
    if (!imgui.begin("Settings", .{})) {
        imgui.end();
        return;
    }

    _ = imgui.checkbox("Paused", .{ .v = &app.is_paused });
    var update_uniform_buffers: bool = false;
    if (imgui.beginCombo("Material", .{ .preview_value = material_names[app.current_material_index] })) {
        for (material_names) |material, material_i| {
            const i = @intCast(u32, material_i);
            if (imgui.selectable(material, .{ .selected = app.current_material_index == i })) {
                update_uniform_buffers = true;
                app.current_material_index = i;
            }
        }
        imgui.endCombo();
    }
    if (imgui.beginCombo("Object type", .{ .preview_value = object_names[app.current_object_index] })) {
        for (object_names) |object, object_i| {
            const i = @intCast(u32, object_i);
            if (imgui.selectable(object, .{ .selected = app.current_object_index == i })) {
                update_uniform_buffers = true;
                app.current_object_index = i;
            }
        }
        imgui.endCombo();
    }
    if (update_uniform_buffers) {
        updateDynamicUniformBuffer(app);
    }
    imgui.end();
}

fn setupImgui(app: *App, core: *mach.Core) void {
    imgui.init();
    const font_normal = imgui.io.addFontFromFile(assets.fonts.roboto_medium.path, 18.0);
    const blend_component_descriptor = gpu.BlendComponent{
        .operation = .add,
        .src_factor = .one,
        .dst_factor = .zero,
    };

    const color_target_state = gpu.ColorTargetState{
        .format = core.swap_chain_format,
        .blend = &.{
            .color = blend_component_descriptor,
            .alpha = blend_component_descriptor,
        },
    };

    const shader_module = core.device.createShaderModuleWGSL("imgui.wgsl", @embedFile("imgui.wgsl"));

    const imgui_pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .depth_stencil = &.{
            .format = .depth24_plus_stencil8,
            .depth_write_enabled = true,
        },
        .fragment = &gpu.FragmentState.init(.{
            .module = shader_module,
            .entry_point = "frag_main",
            .targets = &.{color_target_state},
        }),
        .vertex = gpu.VertexState.init(.{
            .module = shader_module,
            .entry_point = "vert_main",
        }),
    };

    app.imgui_render_pipeline = core.device.createRenderPipeline(&imgui_pipeline_descriptor);

    shader_module.release();

    imgui.io.setDefaultFont(font_normal);
    imgui.backend.init(core.device, core.swap_chain_format, .depth24_plus_stencil8);

    const style = imgui.getStyle();
    style.window_min_size = .{ 350.0, 150.0 };
    style.window_border_size = 8.0;
    style.scrollbar_size = 6.0;
}

fn setupCamera(app: *App, core: *mach.Core) void {
    app.camera = Camera{
        .rotation_speed = 1.0,
        .movement_speed = 1.0,
    };
    const aspect_ratio: f32 = @intToFloat(f32, core.current_desc.width) / @intToFloat(f32, core.current_desc.height);
    app.camera.setPosition(.{ 10.0, 6.0, 6.0 });
    app.camera.setRotation(.{ 62.5, 90.0, 0.0 });
    app.camera.setMovementSpeed(0.5);
    app.camera.setPerspective(60.0, aspect_ratio, 0.1, 256.0);
    app.camera.setRotationSpeed(0.25);
}

inline fn roundToMultipleOf4(comptime T: type, value: T) T {
    return (value + 3) & ~@as(T, 3);
}

inline fn calculateConstantBufferByteSize(byte_size: usize) usize {
    return (byte_size + 255) & ~@as(usize, 255);
}

inline fn toRadians(degrees: f32) f32 {
    return degrees * (std.math.pi / 180.0);
}