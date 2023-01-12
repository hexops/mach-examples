const std = @import("std");
const mach = @import("mach");
const gpu = @import("gpu");
const glfw = @import("glfw");
const zm = @import("zmath");
const Vertex = @import("cube_mesh.zig").Vertex;
const vertices = @import("cube_mesh.zig").vertices;

const UniformBufferObject = struct {
    mat: zm.Mat,
};

var timer: mach.Timer = undefined;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

core: mach.Core,
timer: mach.Timer,
pipeline: *gpu.RenderPipeline,
queue: *gpu.Queue,
vertex_buffer: *gpu.Buffer,
uniform_buffer: *gpu.Buffer,
bind_group1: *gpu.BindGroup,
bind_group2: *gpu.BindGroup,

pub const App = @This();

pub fn init(app: *App) !void {
    app.core = try mach.Core.init(gpa.allocator(), .{});
    app.timer = try mach.Timer.start();

    const shader_module = app.core.device().createShaderModuleWGSL("shader.wgsl", @embedFile("shader.wgsl"));

    const vertex_attributes = [_]gpu.VertexAttribute{
        .{ .format = .float32x4, .offset = @offsetOf(Vertex, "pos"), .shader_location = 0 },
        .{ .format = .float32x2, .offset = @offsetOf(Vertex, "uv"), .shader_location = 1 },
    };
    const vertex_buffer_layout = gpu.VertexBufferLayout.init(.{
        .array_stride = @sizeOf(Vertex),
        .step_mode = .vertex,
        .attributes = &vertex_attributes,
    });

    const blend = gpu.BlendState{};
    const color_target = gpu.ColorTargetState{
        .format = app.core.descriptor().format,
        .blend = &blend,
        .write_mask = gpu.ColorWriteMaskFlags.all,
    };
    const fragment = gpu.FragmentState.init(.{
        .module = shader_module,
        .entry_point = "frag_main",
        .targets = &.{color_target},
    });

    const bgle = gpu.BindGroupLayout.Entry.buffer(0, .{ .vertex = true }, .uniform, true, 0);
    const bgl = app.core.device().createBindGroupLayout(
        &gpu.BindGroupLayout.Descriptor.init(.{
            .entries = &.{bgle},
        }),
    );

    const bind_group_layouts = [_]*gpu.BindGroupLayout{bgl};
    const pipeline_layout = app.core.device().createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
        .bind_group_layouts = &bind_group_layouts,
    }));

    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .fragment = &fragment,
        .layout = pipeline_layout,
        .vertex = gpu.VertexState.init(.{
            .module = shader_module,
            .entry_point = "vertex_main",
            .buffers = &.{vertex_buffer_layout},
        }),
        .primitive = .{
            .cull_mode = .back,
        },
    };

    const queue = app.core.device().getQueue();

    const vertex_buffer = app.core.device().createBuffer(&.{
        .usage = .{ .vertex = true },
        .size = @sizeOf(Vertex) * vertices.len,
        .mapped_at_creation = true,
    });
    var vertex_mapped = vertex_buffer.getMappedRange(Vertex, 0, vertices.len);
    std.mem.copy(Vertex, vertex_mapped.?, vertices[0..]);
    vertex_buffer.unmap();

    // uniformBindGroup offset must be 256-byte aligned
    const uniform_offset = 256;
    const uniform_buffer = app.core.device().createBuffer(&.{
        .usage = .{ .uniform = true, .copy_dst = true },
        .size = @sizeOf(UniformBufferObject) + uniform_offset,
        .mapped_at_creation = false,
    });

    const bind_group1 = app.core.device().createBindGroup(
        &gpu.BindGroup.Descriptor.init(.{
            .layout = bgl,
            .entries = &.{
                gpu.BindGroup.Entry.buffer(0, uniform_buffer, 0, @sizeOf(UniformBufferObject)),
            },
        }),
    );

    const bind_group2 = app.core.device().createBindGroup(
        &gpu.BindGroup.Descriptor.init(.{
            .layout = bgl,
            .entries = &.{
                gpu.BindGroup.Entry.buffer(0, uniform_buffer, uniform_offset, @sizeOf(UniformBufferObject)),
            },
        }),
    );

    app.pipeline = app.core.device().createRenderPipeline(&pipeline_descriptor);
    app.queue = queue;
    app.vertex_buffer = vertex_buffer;
    app.uniform_buffer = uniform_buffer;
    app.bind_group1 = bind_group1;
    app.bind_group2 = bind_group2;

    shader_module.release();
    pipeline_layout.release();
    bgl.release();
}

pub fn deinit(app: *App) void {
    defer _ = gpa.deinit();
    defer app.core.deinit();

    app.vertex_buffer.release();
    app.uniform_buffer.release();
    app.bind_group1.release();
    app.bind_group2.release();
}

pub fn update(app: *App) !bool {
    while (app.core.pollEvents()) |event| {
        switch (event) {
            .key_press => |ev| {
                if (ev.key == .space) return true;
            },
            .close => return true,
            else => {},
        }
    }

    const back_buffer_view = app.core.swapChain().getCurrentTextureView();
    const color_attachment = gpu.RenderPassColorAttachment{
        .view = back_buffer_view,
        .clear_value = std.mem.zeroes(gpu.Color),
        .load_op = .clear,
        .store_op = .store,
    };

    const encoder = app.core.device().createCommandEncoder(null);
    const render_pass_info = gpu.RenderPassDescriptor.init(.{
        .color_attachments = &.{color_attachment},
    });

    {
        const time = timer.read();
        const rotation1 = zm.mul(zm.rotationX(time * (std.math.pi / 2.0)), zm.rotationZ(time * (std.math.pi / 2.0)));
        const rotation2 = zm.mul(zm.rotationZ(time * (std.math.pi / 2.0)), zm.rotationX(time * (std.math.pi / 2.0)));
        const model1 = zm.mul(rotation1, zm.translation(-2, 0, 0));
        const model2 = zm.mul(rotation2, zm.translation(2, 0, 0));
        const view = zm.lookAtRh(
            zm.f32x4(0, -4, 2, 1),
            zm.f32x4(0, 0, 0, 1),
            zm.f32x4(0, 0, 1, 0),
        );
        const proj = zm.perspectiveFovRh(
            (2.0 * std.math.pi / 5.0),
            @intToFloat(f32, app.core.descriptor().width) / @intToFloat(f32, app.core.descriptor().height),
            1,
            100,
        );
        const mvp1 = zm.mul(zm.mul(model1, view), proj);
        const mvp2 = zm.mul(zm.mul(model2, view), proj);
        const ubo1 = UniformBufferObject{
            .mat = zm.transpose(mvp1),
        };
        const ubo2 = UniformBufferObject{
            .mat = zm.transpose(mvp2),
        };

        encoder.writeBuffer(app.uniform_buffer, 0, &[_]UniformBufferObject{ubo1});

        // bind_group2 offset
        encoder.writeBuffer(app.uniform_buffer, 256, &[_]UniformBufferObject{ubo2});
    }

    const pass = encoder.beginRenderPass(&render_pass_info);
    pass.setPipeline(app.pipeline);
    pass.setVertexBuffer(0, app.vertex_buffer, 0, @sizeOf(Vertex) * vertices.len);

    pass.setBindGroup(0, app.bind_group1, &.{0});
    pass.draw(vertices.len, 1, 0, 0);
    pass.setBindGroup(0, app.bind_group2, &.{0});
    pass.draw(vertices.len, 1, 0, 0);

    pass.end();
    pass.release();

    var command = encoder.finish(null);
    encoder.release();

    app.queue.submit(&[_]*gpu.CommandBuffer{command});
    command.release();
    app.core.swapChain().present();
    back_buffer_view.release();

    return false;
}
