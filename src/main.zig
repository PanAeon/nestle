const std = @import("std");
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const zgui = @import("zgui");
const zaudio = @import("zaudio");
const zm = @import("zmath");
const nestle = @import("nestle");
const Emulator = nestle.Emulator;
const JoystickState = nestle.core.Controller.JoystickState;
// const OldMain = @import("oldmain.zig");
// const stb_image = @import("stb_image.zig");

const gl = zopengl.bindings;

pub var window: *glfw.Window = undefined;

const gl_version_major: u16 = 4;
const gl_version_minor: u16 = 5;
const content_dir = @import("build_options").content_dir;

const NES_WIDTH: usize = 256;
const NES_HEIGHT: usize = 240; //224...

const vertexShaderSource =
    \\#version 300 es
    \\
    \\// an attribute is an input (in) to a vertex shader.
    \\// It will receive data from a buffer
    \\in vec2 a_position;
    \\in vec2 a_texcoord;
    \\
    \\// A matrix to transform the positions by
    \\uniform mat4 u_matrix;
    \\
    \\out vec2 v_texcoord;
    \\
    \\// all shaders have a main function
    \\void main() {
    \\  // Multiply the position by the matrix.
    \\  gl_Position = vec4((u_matrix * vec4(a_position, 0, 1)).xy, 0, 1);
    \\  v_texcoord = a_texcoord;
    \\  //gl_Position = vec4(a_position, 0, 1); 
    \\  //gl_Position = vec4(0.0, 0.0, 0.0, 1);
    \\}  
;

const fragmentShaderSource =
    \\#version 300 es
    \\
    \\precision highp float;
    \\
    \\in vec2 v_texcoord;
    \\uniform sampler2D u_texture;
    \\
    \\out vec4 outColor;
    \\
    \\void main() {
    \\  outColor = texture(u_texture, v_texcoord);
    \\}
;

pub fn main() !void {
    { // Change current working directory to where the executable is located.
        var buffer: [1024]u8 = undefined;
        const path = std.fs.selfExeDirPath(buffer[0..]) catch ".";
        try std.posix.chdir(path);
    }

    // if (true) {
    //     try OldMain.main();
    //     return;
    // }

    try glfw.init();
    defer glfw.terminate();

    glfw.windowHint(.client_api, .opengl_api);
    glfw.windowHint(.context_version_major, gl_version_major);
    glfw.windowHint(.context_version_minor, gl_version_minor);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    glfw.windowHint(.opengl_forward_compat, true);
    glfw.windowHint(.doublebuffer, true);
    glfw.windowHint(.wayland_app_id, "testglfw");
    // glfw.windowHint(.mouse_passthrough, true);
    glfw.windowHint(.scale_to_monitor, false);
    glfw.windowHint(.scale_framebuffer, false);

    try init();
    defer deinit();
}

pub fn compileShader(shader_type: u32, source: []const u8) c_uint {
    const shader = gl.createShader(shader_type);
    const srcs = [_][]const u8{source};
    const sizes = [_][1]usize{[_]usize{source.len}};
    gl.shaderSource(shader, 1, @ptrCast(&srcs), @ptrCast(&sizes));
    gl.compileShader(shader);

    var success: i32 = 0;
    gl.getShaderiv(shader, gl.COMPILE_STATUS, &success);

    if (!(success != 0)) {
        var length: i32 = 0;
        var buffer: [1024:0]u8 = std.mem.zeroes([1024:0]u8);
        gl.getShaderInfoLog(shader, 1024, &length, &buffer);
        std.debug.print("shader info log: {s}\n", .{buffer});
        @panic("shader didn't compile");
    }

    return shader;
}

pub fn init() !void {
    window = try glfw.Window.create(NES_WIDTH * 2, NES_HEIGHT * 2, "nestle", null);

    glfw.makeContextCurrent(window);
    // const monitor = glfw.getWindowMonitor(window);
    // monitor.?.*.

    glfw.swapInterval(0); // disable refresh rate sync
    try zopengl.loadCoreProfile(glfw.getProcAddress, 4, gl_version_minor);

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    zgui.init(gpa);
    defer zgui.deinit();

    zaudio.init(gpa);
    defer zaudio.deinit();

    const engine = try zaudio.Engine.create(null);
    defer engine.destroy();

    // const music = try engine.createSoundFromFile(
    //     content_dir ++ "serbia_strong.mp3",
    //     .{ .flags = .{ .stream = true } },
    // );
    // defer music.destroy();
    // try music.start();

    // window.setContentScale(2.0);
    var imageData: [NES_WIDTH * NES_HEIGHT]u32 = .{0x00000000} ** (NES_WIDTH * NES_HEIGHT);

    var emulator: Emulator = undefined;
    try Emulator.init(gpa, &imageData, &emulator, engine);
    defer emulator.deinit(gpa);

    // try emulator.run_cpu_test();
    // if (true) return;

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };
    std.debug.print("scale factor {d}\n", .{scale_factor});
    // scale_factor = 2.0;
    _ = zgui.io.addFontFromFile(
        "content/Roboto-Medium.ttf",
        std.math.floor(16.0 * scale_factor),
    );

    zgui.getStyle().scaleAllSizes(scale_factor);
    zgui.getStyle().font_size_base = 21.0;

    const program = gl.createProgram();

    const vertexShader = compileShader(gl.VERTEX_SHADER, vertexShaderSource[0..]);
    const fragmentShader = compileShader(gl.FRAGMENT_SHADER, fragmentShaderSource[0..]);

    gl.attachShader(program, vertexShader);
    gl.attachShader(program, fragmentShader);
    // gl.getProgramInfoLog(program, bufSize: c_int, length: [*c]c_int, infoLog: [*c]u8)

    gl.linkProgram(program);

    var success: i32 = 0;
    gl.getProgramiv(program, gl.LINK_STATUS, &success);

    if (!(success != 0)) {
        var length: i32 = 0;
        var buffer: [1024:0]u8 = std.mem.zeroes([1024:0]u8);
        gl.getProgramInfoLog(program, 1024, &length, &buffer);
        std.debug.print("program info log: {s}\n", .{buffer});
        @panic("program didn't link");
    }

    gl.useProgram(program);
    // gl.viewport(0, 0, NES_WIDTH*2, NES_HEIGHT*2);

    const positionAttrLocation = gl.getAttribLocation(program, "a_position");
    const texCoordAttrLocation = gl.getAttribLocation(program, "a_texcoord");
    const projection_matrix = gl.getUniformLocation(program, "u_matrix");
    const colorLocation = gl.getUniformLocation(program, "u_color");

    var buffers: [3]u32 = .{ 0, 0, 0 };
    gl.createBuffers(3, buffers[0..]);

    var vaos: [3]u32 = .{ 0, 0, 0 };
    gl.createVertexArrays(3, &vaos);
    // const vao = vaos[0];

    // gl.bindVertexArray(vao);
    // gl.enableVertexAttribArray(@bitCast(positionAttrLocation));

    // gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer);

    // {
    //     const data = [_]f32{
    //         0,  0,
    //         30, 0,
    //         0,  150,
    //         0,  150,
    //         30, 0,
    //         30, 150,
    //     };
    //     // gl.drawElements(gl.TRIANGLES, t, type: c_uint, indices: ?*const anyopaque)
    //
    //     gl.bufferData(gl.ARRAY_BUFFER, 4 * data.len, &data, gl.STATIC_DRAW);
    // }

    // const size = 2; // 2 components per iteration
    // const @"type" = gl.FLOAT; // the data is 32bit floats
    // const normalize: u8 = 0; // don't normalize the data
    // const stride: u8 = 0; // 0 = move forward size * sizeof(type) each iteration to get the next position
    // const offset: ?*const anyopaque = null; // start at the beginning of the buffer
    // gl.vertexAttribPointer(@bitCast(positionAttrLocation), size, @"type", normalize, stride, offset);

    // const numStripes = comptime 20;

    gen_triangles(vaos[0], positionAttrLocation, buffers[0]);
    gen_tex_coords(vaos[0], texCoordAttrLocation, buffers[1]);

    // Create a texture.
    var textures: [1]u32 = .{0};
    gl.createTextures(gl.TEXTURE_2D, 1, &textures);
    // const texture = gl.createTexture();

    // Fill the texture with a 1x1 blue pixel.
    // const foo = [_]u8{0, 0, 255, 255};
    // gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE,
    //               &foo);
    // const foo = [_]u8{0, 0, 255, 255}**(256*256);
    // gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE,
    //               &foo);

    {
        // for (0..128) |y| {
        //     for (0..128) |x| {
        //         const i = x + y * 256;
        //         imageData[i*4] = 255;
        //         imageData[i*4+1] = 0;
        //         imageData[i*4+2] = 0;
        //         imageData[i*4+3] = 255;
        //     }
        // }
        // now draw an F
        // for (40..200) |y| {
        //     for (80..160) |x| {
        //         imageData[ x*4 + 4*y*256] = 255;
        //         imageData[ x*4 + 4*y*256+3] = 255;
        //     }
        // }
        gl.bindTexture(gl.TEXTURE_2D, textures[0]);
        gl.textureParameteri(textures[0], gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.textureParameteri(textures[0], gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, NES_WIDTH, NES_HEIGHT, 0, gl.RGBA, gl.UNSIGNED_BYTE, &imageData);
        gl.generateMipmap(gl.TEXTURE_2D);
    }

    // Asynchronously load an image
    // var image = new Image();
    // image.src = "resources/f-texture.png";
    // image.addEventListener('load', function() {
    //   // Now that the image has loaded make copy it to the texture.
    //   gl.bindTexture(gl.TEXTURE_2D, texture);
    //   gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA,gl.UNSIGNED_BYTE, image);
    //   gl.generateMipmap(gl.TEXTURE_2D);
    // });

    const fps_target: f64 = 60.0;
    const frame_time: f64 = 1.0 / fps_target;
    var lastFrameTime: f64 = glfw.getTime();

    const color: [4]f32 = .{ 0.7, 0.74, 0.99, 1.0 };

    var threaded: std.Io.Threaded = .init_single_threaded;

    zgui.backend.init(window);
    defer zgui.backend.deinit();
    const joystick: glfw.Joystick = @enumFromInt(1);
    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        const current_time = glfw.getTime();
        const delta = current_time - lastFrameTime;
        if (delta < frame_time) {
            std.Io.sleep(threaded.io(), std.Io.Duration.fromMilliseconds(@intFromFloat(1000 * (frame_time - delta))), std.Io.Clock.real) catch {
                std.debug.print("can't sleep", .{});
            };
        }
        lastFrameTime = glfw.getTime();
        // updateAndRender();
        glfw.pollEvents();
        // const jj = try glfw.joystickAsGamepad(joystick).?.getState();

        const buttons = try glfw.getJoystickButtons(joystick);
        const jstate: JoystickState = .{ .buttonA = buttons[0] == .press, .buttonB = buttons[1] == .press, .select = buttons[6] == .press, .start = buttons[7] == .press, .left = buttons[14] == .press, .right = buttons[12] == .press, .up = buttons[11] == .press, .down = buttons[13] == .press };
        emulator.setJoystickState(jstate);
        // for (buttons, 0..) |b,i| {
        //     if (b == .press) {
        //       std.debug.print("joystick: {d}\n", .{i});
        //     }
        // }

        // if (window.getKey(.left) == .press and
        //     (gameState.pad_x - pad_half_len - 8.0 > -field_width))
        // {
        //     gameState.pad_x -= pad_speed;
        // }
        // if (window.getKey(.right) == .press and
        //     (gameState.pad_x + pad_half_len + 8.0 < field_width))
        // {
        //     gameState.pad_x += pad_speed;
        // }
        //
        // if (window.getKey(.space) == .press and
        //     !gameState.game_started)
        // {
        //     gameState.game_started = true;
        // }
        emulator.run_one_frame();

        // gl.useProgram(program);
        gl.bindVertexArray(vaos[0]);

        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.clearColor(0.118, 0.118, 0.180, 1.0);

        gl.uniform4fv(colorLocation, 1, color[0..]);
        // const ortho = zm.orthographicLhGl(1920.0, 1080.0, 0.0, 1.0);
        const ortho = zm.orthographicOffCenterLhGl(0.0, 2.0 * @as(f32, @floatFromInt(NES_WIDTH)), 0.0, 2.0 * @as(f32, @floatFromInt(NES_HEIGHT)), 0.0, 1.0);
        gl.uniformMatrix4fv(projection_matrix, 1, 0, zm.arrNPtr(&ortho));
        gl.bindTexture(gl.TEXTURE_2D, textures[0]);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, NES_WIDTH, NES_HEIGHT, 0, gl.RGBA, gl.UNSIGNED_BYTE, &imageData);
        gl.generateMipmap(gl.TEXTURE_2D);

        // const err = gl.getError();
        //        std.debug.print("err: {d}\n", .{err});
        // if (err != 0) {
        //         @panic("err");
        //     }

        // const primitiveType = gl.TRIANGLES;
        // const _offset = 0;
        // const count = 6;
        gl.drawArrays(gl.TRIANGLES, 0, 6);

        // const fb_size = window.getFramebufferSize();
        // std.debug.print("fb size: {d}, {d}\n", .{fb_size[0], fb_size[1]});

        // zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));

        // zgui.showDemoWindow(null);

        // Set the starting window position and size to custom values
        // zgui.setNextWindowPos(.{ .x = 20.0, .y = 20.0, .cond = .first_use_ever });
        // zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });

        // if (zgui.beginMainMenuBar()) {
        //     if (zgui.beginMenu("File", true)) {
        //         _ = zgui.menuItem("Open", .{});
        //         _ = zgui.menuItem("Close", .{});
        //         _ = zgui.menuItem("Exit", .{});
        //         zgui.endMenu();
        //     }
        //     if (zgui.beginMenu("Edit", true)) {
        //         _ = zgui.menuItem("Cut", .{});
        //         _ = zgui.menuItem("Paste", .{});
        //         _ = zgui.menuItem("Find", .{});
        //         zgui.endMenu();
        //     }
        //     zgui.endMainMenuBar();
        // }

        // if (zgui.begin("My window", .{})) {
        //     if (zgui.button("Press me!", .{ .w = 200.0 })) {
        //         std.debug.print("Button pressed\n", .{});
        //     }
        // }
        // zgui.end();

        // zgui.backend.draw();

        window.swapBuffers();
    }
}

pub fn gen_triangles(vao: u32, positionAttrLocation: i32, positionBuffer: u32) void {
    gl.bindVertexArray(vao);
    gl.enableVertexAttribArray(@bitCast(positionAttrLocation));

    gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer);

    // 6 vertices for each brick,
    // let's do the paddle first
    var data: [12]f32 = .{0} ** 12;
    data[0] = 0.0;
    data[1] = 0.0;
    data[2] = NES_WIDTH * 2;
    data[3] = 0.0;
    data[4] = NES_WIDTH * 2;
    data[5] = NES_HEIGHT * 2;

    data[6] = NES_WIDTH * 2;
    data[7] = NES_HEIGHT * 2;
    data[8] = 0.0;
    data[9] = NES_HEIGHT * 2;
    data[10] = 0.0;
    data[11] = 0.0;

    // const num_points: i32 = 6;

    // 4 * @as(isize , @intCast(data_idx))
    gl.bufferData(gl.ARRAY_BUFFER, 4 * data.len, &data, gl.STATIC_DRAW);

    const size = 2; // 2 components per iteration
    const @"type" = gl.FLOAT; // the data is 32bit floats
    const normalize: u8 = 0; // don't normalize the data
    const stride: u8 = 0; // 0 = move forward size * sizeof(type) each iteration to get the next position
    const offset: ?*const anyopaque = null; // start at the beginning of the buffer
    gl.vertexAttribPointer(@bitCast(positionAttrLocation), size, @"type", normalize, stride, offset);
}

pub fn gen_tex_coords(vao: u32, texAttrLocation: i32, texBuffer: u32) void {
    gl.bindVertexArray(vao);
    gl.enableVertexAttribArray(@bitCast(texAttrLocation));

    gl.bindBuffer(gl.ARRAY_BUFFER, texBuffer);

    // 6 vertices for each brick,
    // let's do the paddle first
    var data: [12]f32 = .{
        0, 0,
        1, 0,
        1, 1,
        1, 1,
        0, 1,
        0, 0,
    };

    // const num_points: i32 = 6;

    // 4 * @as(isize , @intCast(data_idx))
    gl.bufferData(gl.ARRAY_BUFFER, @sizeOf(f32) * data.len, &data, gl.STATIC_DRAW);

    const size = 2; // 2 components per iteration
    const @"type" = gl.FLOAT; // the data is 32bit floats
    const normalize: u8 = 1;
    const stride: u8 = 0; // 0 = move forward size * sizeof(type) each iteration to get the next position
    const offset: ?*const anyopaque = null; // start at the beginning of the buffer
    gl.vertexAttribPointer(@bitCast(texAttrLocation), size, @"type", normalize, stride, offset);
}
pub fn deinit() void {
    window.destroy();
    glfw.terminate();
}
