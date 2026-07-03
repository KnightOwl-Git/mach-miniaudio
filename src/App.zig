const std = @import("std");
const mach = @import("mach");
const gpu = mach.gpu;
const c = @import("c");

const App = @This();

// The set of Mach modules our application may use.
pub const Modules = mach.Modules(.{
    mach.Core,
    App,
});

pub const mach_module = .app;

pub const mach_systems = .{
    .main,
    .init,
    .appTick,
    .tick,
    .render,
    .deinit,
};

pub const main = mach.schedule(.{
    .{ mach.Core, .init },
    .{ App, .init },
    .{ mach.Core, .main },
});

pipeline: ?*gpu.RenderPipeline = null,
app_thread: mach.Thread,
window: mach.ObjectID,

const bgm_data = @embedFile("bit_bit_loop_kevin_macleod.wav");
const sfx_data = @embedFile("sword1.wav");

var bgm_decoder: c.ma_decoder = undefined;
var sfx_decoder: c.ma_decoder = undefined;
var device: c.ma_device = undefined;

fn dataCallback(p_device: [*c]c.ma_device, p_output: ?*anyopaque, p_input: ?*const anyopaque, frame_count: c.ma_uint32) callconv(.c) void {
    _ = p_device;
    _ = p_input; // autofix
    var frames_read: u64 = 0;
    var bgm_output: [4096]f32 = undefined;
    var result = c.ma_decoder_read_pcm_frames(&bgm_decoder, &bgm_output, frame_count, &frames_read);

    var sfx_output: [4096]f32 = undefined;
    var sfx_frames_read: u64 = 0;
    result = c.ma_decoder_read_pcm_frames(&sfx_decoder, &sfx_output, frame_count, &sfx_frames_read);

    // if (result != c.MA_SUCCESS) {
    //     std.log.err("could not read frames \n", .{});
    // }
    if (frames_read < frame_count) {
        //reached the end. loop
        if (c.ma_decoder_seek_to_pcm_frame(&bgm_decoder, 0) != c.MA_SUCCESS) {
            std.log.err("could not loop music\n", .{});
        }
    }

    //mixing samples

    const sample_count = frame_count * device.playback.channels;

    const p_output_pointer: [*]f32 = @ptrCast(@alignCast(p_output));
    const p_output_to_mix = p_output_pointer[0..sample_count];

    //lower volume
    for (p_output_to_mix, 0..) |*value, i| {
        value.* += bgm_output[i] + sfx_output[i];
        value.* *= 0.1;
    }
}

pub fn init(
    core: *mach.Core,
    app: *App,
    app_mod: mach.Mod(App),
    core_mod: mach.Mod(mach.Core),
) !void {
    core.on_exit = app_mod.id.deinit;

    const window = try core.windows.new(.{
        .title = "Hello, Mach!",
        .on_render = app_mod.id.render,
    });

    var config = c.ma_device_config_init(c.ma_device_type_playback);

    config.playback.format = c.ma_format_f32;
    config.playback.channels = 2;
    config.sampleRate = 48000;
    config.periodSizeInFrames = 16; //Set buffer size to 16 frames, the lowest it'll go on Mac.
    config.dataCallback = dataCallback;
    //

    if (c.ma_device_init(null, &config, &device) != c.MA_SUCCESS) {
        return error.DeviceInitFailed;
    }

    //set up opus decoder
    const opus_decoder: [*c][*c]c.ma_decoding_backend_vtable = &c.ma_decoding_backend_libopus;

    var decoder_config = c.ma_decoder_config_init_default();

    decoder_config.ppCustomBackendVTables = opus_decoder;
    decoder_config.customBackendCount = 1;
    decoder_config.sampleRate = device.sampleRate;
    decoder_config.format = device.playback.format;
    decoder_config.channels = device.playback.channels;

    //load bgm

    if (c.ma_decoder_init_memory(bgm_data, bgm_data.len, &decoder_config, &bgm_decoder) != c.MA_SUCCESS) {
        return error.FileInitError;
    }
    //load sfx
    if (c.ma_decoder_init_memory(sfx_data, sfx_data.len, &decoder_config, &sfx_decoder) != c.MA_SUCCESS) {
        return error.FileInitError;
    }

    //start sfx at the end of the file
    _ = c.ma_decoder_seek_to_pcm_frame(&sfx_decoder, sfx_data.len);

    //create device

    if (c.ma_device_start(&device) != c.MA_SUCCESS) {
        return error.DeviceStartError;
    }

    // check actual buffer size
    const actual_buffer_size = device.playback.internalPeriodSizeInFrames;
    std.debug.print("actual buffer size: {}\n", .{actual_buffer_size});

    // Store our render pipeline in our module's state, so we can access it later on.
    app.* = .{
        .app_thread = try mach.startThread(core, app_mod.id.tick, core_mod, .app),
        .window = window,
    };
}

fn setupPipeline(core: *mach.Core, app: *App) !void {
    var window = core.windows.getValue(core.window);
    defer core.windows.setValueRaw(core.window, window);

    // Create our shader module
    const shader_module = window.device.createShaderModuleWGSL("shader.wgsl", @embedFile("shader.wgsl"));
    defer shader_module.release();

    // Blend state describes how rendered colors get blended
    const blend = gpu.BlendState{};

    // Color target describes e.g. the pixel format of the window we are rendering to.
    const color_target = gpu.ColorTargetState{
        .format = window.framebuffer_format,
        .blend = &blend,
    };

    // Fragment state describes which shader and entrypoint to use for rendering fragments.
    const fragment = gpu.FragmentState.init(.{
        .module = shader_module,
        .entry_point = "frag_main",
        .targets = &.{color_target},
    });

    // Create our render pipeline that will ultimately get pixels onto the screen.
    const label = @tagName(mach_module) ++ ".init";
    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .label = label,
        .fragment = &fragment,
        .vertex = gpu.VertexState{
            .module = shader_module,
            .entry_point = "vertex_main",
        },
    };
    app.pipeline = window.device.createRenderPipeline(&pipeline_descriptor);
}

pub const tick = mach.schedule(.{
    .{ App, .appTick },
    .{ mach.Core, .snapshotStart },
    .{ mach.Core, .snapshotEnd },
});

pub fn appTick(core: *mach.Core) void {
    var iter = core.events(.default);
    while (iter.next()) |event| {
        switch (event) {
            .close => core.exit(),
            .key_press => |key| {
                switch (key.key) {
                    .escape => core.exit(),
                    else => {
                        _ = c.ma_decoder_seek_to_pcm_frame(&sfx_decoder, 7000); //skip silence to make low latency apparent
                    },
                }
            },
            else => {},
        }
    }
}

pub fn render(app: *App, core: *mach.Core) !void {
    const pipeline = app.pipeline orelse {
        try setupPipeline(core, app);
        return;
    };
    const label = @tagName(mach_module) ++ ".render";
    const window = core.windows.getValue(core.window);

    // Grab the back buffer of the swapchain
    // TODO(core): this wouldn't exist in browser
    const back_buffer_view = window.swap_chain.getCurrentTextureView() orelse return;
    defer back_buffer_view.release();

    // Create a command encoder
    const encoder = window.device.createCommandEncoder(&.{ .label = label });
    defer encoder.release();

    // Begin render pass
    const sky_blue_background = gpu.Color{ .r = 0.776, .g = 0.988, .b = 1, .a = 1 };
    const color_attachments = [_]gpu.RenderPassColorAttachment{.{
        .view = back_buffer_view,
        .clear_value = sky_blue_background,
        .load_op = .clear,
        .store_op = .store,
    }};
    const render_pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
        .label = label,
        .color_attachments = &color_attachments,
    }));
    defer render_pass.release();

    // Draw
    render_pass.setPipeline(pipeline);
    render_pass.draw(3, 1, 0, 0);

    // Finish render pass
    render_pass.end();

    // Submit our commands to the queue
    var command = encoder.finish(&.{ .label = label });
    defer command.release();
    window.queue.submit(&[_]*gpu.CommandBuffer{command});

    {
        core.windows.lock();
        defer core.windows.unlock();
        try core.fmtTitle(app.window, "Hello, Mach! [ {d}fps ] [ Input {d}hz ]", .{
            core.frame.rate, core.input.rate,
        });
    }
}

pub fn deinit(app: *App) void {
    app.app_thread.join();
    if (app.pipeline) |p| p.release();
}
