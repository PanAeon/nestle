const std = @import("std");
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const zgui = @import("zgui");
const zaudio = @import("zaudio");
const zm = @import("zmath");
const nestle = @import("nestle");
const Rewind = @import("Rewind.zig");
const Emulator = nestle.Emulator;
const JoystickState = nestle.core.Controller.JoystickState;
// const OldMain = @import("oldmain.zig");
// const stb_image = @import("stb_image.zig");

const gl = zopengl.bindings;

pub var window: *glfw.Window = undefined;

const gl_version_major: u16 = 4;
const gl_version_minor: u16 = 6;
// const content_dir = @import("build_options").content_dir;

const NES_WIDTH: usize = 256;
const NES_HEIGHT: usize = 240; //224...
const NES_WIDTH_F: f32 = 256.0;
const NES_HEIGHT_F: f32 = 240.0; //224...

// FIXME: zelda sprite rotated wrong
// TODO: Options
const VideoOptions = struct {
    integerScaling: bool = false,
    linearFilter: bool = true,
};

var videoOptions: VideoOptions = .{};

// const ShaderSrc = @embedFile("shaders/stock.glsl");
const ShaderSrc = @embedFile("shaders/crt-easymode.glsl");
// const ShaderSrc = @embedFile("shaders/crt-geom.glsl");
// const ShaderSrc = @embedFile("shaders/CRTShader.glsl");
const VertexShader = "#version 450\n#define VERTEX\n" ++ ShaderSrc;
const FragmentShader = "#version 450\n#define FRAGMENT\n" ++ ShaderSrc;

pub fn main(innit: std.process.Init) !void {
    { // Change current working directory to where the executable is located.
        var buffer: [1024]u8 = undefined;
        // const path =  std.Io.Dir.cwd();
        const len = std.process.executablePath(innit.io, &buffer) catch {
            @panic("foo");
        };
        buffer[len] = 0;
        // std.Io.Dir.
        // const path = std.fs.selfExeDirPath(buffer[0..]) catch ".";
        _ = std.os.linux.chdir(buffer[0..len :0]);
    }

    const homeDir = innit.environ_map.get("HOME").?; 
    if (innit.minimal.args.vector.len != 2) {
        @panic("expecting exactly one argument");
    }
    const args= try innit.minimal.args.toSlice(innit.arena.allocator());
    const romPath = args[1];
    // const home_dir = try std.process.getEnvVarOwned(allocator, "HOME");

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

    try init(homeDir, romPath);
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

pub fn init(homeDir: []const u8, romPath: []const u8) !void {
    window = try glfw.Window.create(NES_WIDTH * 2, NES_HEIGHT * 2, "nestle", null,  null);

    glfw.makeContextCurrent(window);
    // const monitor = glfw.getWindowMonitor(window);
    // monitor.?.*.

    glfw.swapInterval(0); // disable refresh rate sync
    try zopengl.loadCoreProfile(glfw.getProcAddress, 4, gl_version_minor);

    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    zgui.init(gpa);
    defer zgui.deinit();

    zaudio.init(gpa);
    defer zaudio.deinit();

    // const engine = try zaudio.Engine.create(null);
    // defer engine.destroy();

    // const music = try engine.createSoundFromFile(
    //     content_dir ++ "serbia_strong.mp3",
    //     .{ .flags = .{ .stream = true } },
    // );
    // defer music.destroy();
    // try music.start();

    // window.setContentScale(2.0);
    var imageData: [NES_WIDTH * NES_HEIGHT]u32 = .{0x00000000} ** (NES_WIDTH * NES_HEIGHT);

    var emulator: Emulator = undefined;
    try Emulator.init(gpa, &imageData, &emulator, romPath);
    defer emulator.deinit(gpa);

    // try emulator.saveStateToFile(gpa, 1);
    // try emulator.loadStateFromFile(gpa, 1);

    const rewBuffer = try gpa.alloc(u8, emulator.byteSize());
    defer gpa.free(rewBuffer);
    var rewWriter = std.Io.Writer.fixed(rewBuffer);

    var rewind = try Rewind.init(gpa, emulator.byteSize()); 
    defer rewind.deinit(gpa);

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

    const vertexShader = compileShader(gl.VERTEX_SHADER, VertexShader[0..]);
    const fragmentShader = compileShader(gl.FRAGMENT_SHADER, FragmentShader[0..]);
    // const fragmentShader = compileShader(gl.FRAGMENT_SHADER, fragmentShaderSource[0..]);

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
    // shader uniforms:
    //
// uniform COMPAT_PRECISION vec2 OutputSize;
// uniform COMPAT_PRECISION vec2 TextureSize;
// uniform COMPAT_PRECISION vec2 InputSize;
    const outputSize = gl.getUniformLocation(program, "OutputSize");
    const textureSize = gl.getUniformLocation(program, "TextureSize");
    const inputSize = gl.getUniformLocation(program, "InputSize");
    const frameCount = gl.getUniformLocation(program, "FrameCount");

    gl.uniform2f(outputSize, 2.0*NES_WIDTH_F, 2.0*NES_HEIGHT_F);
    gl.uniform2f(textureSize, NES_WIDTH_F, NES_HEIGHT_F);
    gl.uniform2f(inputSize, NES_WIDTH_F, NES_HEIGHT_F);
    //
    //
    // const tDiffuse = gl.getUniformLocation(program, "tDiffuse");
    // const scanlineIntensity= gl.getUniformLocation(program, "scanlineIntensity");
    // const scanlineCount= gl.getUniformLocation(program, "scanlineCount");
    // const time= gl.getUniformLocation(program, "time");
    // const yOffset= gl.getUniformLocation(program, "yOffset");
    // const brightness= gl.getUniformLocation(program, "brightness");
    // const contrast= gl.getUniformLocation(program, "contrast");
    // const saturation= gl.getUniformLocation(program, "saturation");
    // const bloomIntensity= gl.getUniformLocation(program, "bloomIntensity");
    // const bloomThreshold= gl.getUniformLocation(program, "bloomThreshold");
    // const rgbShift= gl.getUniformLocation(program, "rgbShift");
    // const adaptiveIntensity= gl.getUniformLocation(program, "adaptiveIntensity");
    // const vignetteStrength= gl.getUniformLocation(program, "vignetteStrength");
    // const curvature = gl.getUniformLocation(program, "curvature");
    // const flickerStrength = gl.getUniformLocation(program, "flickerStrength");
    // gl.uniform1f(tDiffuse, 
    // gl.uniform1f(scanlineIntensity, 0.15);
    // gl.uniform1f(scanlineCount, 256);
    // gl.uniform1f(time, 0);
    // gl.uniform1f(yOffset, 0);
    // gl.uniform1f(brightness, 1.1);
    // gl.uniform1f(contrast, 1.05);
    // gl.uniform1f(saturation, 1.1);
    // gl.uniform1f(bloomIntensity, 0.2);
    // gl.uniform1f(bloomThreshold, 0.5);
    // gl.uniform1f(rgbShift, 0.0);
    // gl.uniform1f(adaptiveIntensity, 0.5);
    // gl.uniform1f(vignetteStrength, 0.3);
    // gl.uniform1f(curvature, 0.15);
    // gl.uniform1f(flickerStrength, 0.01);
    // const tDiffuse: { value: null },
    // scanlineIntensity: { value: 0.15 },
    // scanlineCount: { value: 400.0 },
    // time: { value: 0.0 },
    // yOffset: { value: 0.0 },
    // brightness: { value: 1.1 },
    // contrast: { value: 1.05 },
    // saturation: { value: 1.1 },
    // bloomIntensity: { value: 0.2 },
    // bloomThreshold: { value: 0.5 },
    // rgbShift: { value: 0.0 },
    // adaptiveIntensity: { value: 0.5 },
    // vignetteStrength: { value: 0.3 },
    // curvature: { value: 0.15 },
    // flickerStrength: { value: 0.01 }
    //

    const positionAttrLocation = gl.getAttribLocation(program, "VertexCoord");
    const texCoordAttrLocation = gl.getAttribLocation(program, "TexCoord");
    const projection_matrix = gl.getUniformLocation(program, "MVPMatrix");
    const colorLocation = gl.getUniformLocation(program, "COLOR");

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

    var prevFBSize = window.getFramebufferSize();
    gen_triangles(vaos[0], positionAttrLocation, outputSize, buffers[0], prevFBSize);
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
        if (videoOptions.linearFilter) {
            gl.textureParameteri(textures[0], gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        } else {
            gl.textureParameteri(textures[0], gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        }
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, NES_WIDTH, NES_HEIGHT, 0, gl.RGBA, gl.UNSIGNED_BYTE, &imageData);
        // gl.generateMipmap(gl.TEXTURE_2D);
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
    _ = glfw.setFramebufferSizeCallback(window, onChangeFBSize);

    const fps_target: f64 = 60.0;
    const frame_time: f64 = 1.0 / fps_target;
    var lastFrameTime: f64 = glfw.getTime();

    const color: [4]f32 = .{ 0.7, 0.74, 0.99, 1.0 };

    var threaded: std.Io.Threaded = .init_single_threaded;
    var space_debounce: bool = false;
    var one_debounce: bool = false;
    var f3_debounce: bool = false;
    var save_debounce: bool = false;
    var load_debounce: bool = false;
    _ = &save_debounce;
    _ = &load_debounce;
    var currentSlot: u8 = 1;
    var slowdown: bool = false;
    var rew: bool = false;
    var rewStarted: bool = false;
    var rewCursor: usize = 0;
    var isEven : bool = false;
    var frameNumber: u16 = 0;
    // var writer = try std.Io.Writer.Allocating.initCapacity(gpa, 16000);
    // defer writer.deinit();
    var textBuffer: [1024]u8 = std.mem.zeroes([1024]u8);
    var textTimeout: u64 = 0;
    var text: []u8 = &.{};

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

        gl.uniform1i(frameCount, frameNumber);
        frameNumber +%= 1;
        // updateAndRender();
        glfw.pollEvents();
        const fb_size = window.getFramebufferSize();
        if (fb_size[0] != prevFBSize[0] or fb_size[1] != prevFBSize[1]) {
            gen_triangles(vaos[0], positionAttrLocation, outputSize, buffers[0], fb_size);
            prevFBSize[0] = fb_size[0];
            prevFBSize[1] = fb_size[1];
        }
        if (window.getKey(.space) == .press and !space_debounce) { // TODO: macro or something?
            space_debounce = true;
            slowdown = ~slowdown;
        }
        if (space_debounce and window.getKey(.space) == .release) {
            space_debounce = false;
        }
        // if (window.getKey(.one) == .press  and !one_debounce) { // TODO: macro or something?
        //     one_debounce = true;
        //     _ = writer.writer.consumeAll();
        //     try emulator.saveState(&writer.writer);
        //     std.debug.print("Jesus saves\n", .{});
        // }
        if (one_debounce and window.getKey(.one) == .release) {
            one_debounce = false;
        }
        // if (window.getKey(.F3) == .press  and !f3_debounce) { // TODO: macro or something?
        //     f3_debounce = true;
        //     var reader  = std.Io.Reader.fixed(writer.written());
        //     try emulator.loadState(&reader);
        //     std.debug.print("loading...\n", .{});
        // }
        if (f3_debounce and window.getKey(.F3) == .release) {
            f3_debounce = false;
        }
        rew = (window.getKey(.backspace) == .press);

        if (window.getKey(.one) == .press) {
            currentSlot = 1;
        }

        // const gamepad = try glfw.joystickAsGamepad(joystick).?.getState();
        // const buttons = gamepad.buttons;

        if (glfw.joystickPresent(joystick)) {
            const buttons = try glfw.getJoystickButtons(joystick);
            const jstate: JoystickState = .{ .buttonA = buttons[0] == .press, .buttonB = buttons[1] == .press, .select = buttons[6] == .press, .start = buttons[7] == .press, .left = buttons[14] == .press, .right = buttons[12] == .press, .up = buttons[11] == .press, .down = buttons[13] == .press };
            emulator.setJoystickState(jstate);
            const axes = try glfw.getJoystickAxes(joystick);
            slowdown =  (axes[5] > 0.18);
            rew = rew | (axes[2] > 0.18);
            // std.debug.print("buttons: {any}\n", .{buttons});
            // std.debug.print("axes: {d}\n", .{axes[5]});
            if (buttons[4] == .press and !load_debounce) {
                try emulator.loadStateFromFile(gpa, currentSlot, homeDir);
                text = try std.fmt.bufPrint(&textBuffer, "state {d} loaded", .{currentSlot});
                textTimeout = 60*3;
            }
            load_debounce = buttons[4] == .press;
            if (buttons[5] == .press and !save_debounce) {
                try emulator.saveStateToFile(gpa, currentSlot, homeDir);
                text = try std.fmt.bufPrint(&textBuffer, "state {d} saved", .{currentSlot});
                textTimeout = 60*3;
            }
            save_debounce = buttons[5] == .press;
        }

        if (slowdown) {
            try std.Io.sleep(threaded.io(), std.Io.Duration.fromMilliseconds(@intFromFloat(1000 * (frame_time))), std.Io.Clock.real);
        }
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
        if (rew) {
            if (rewStarted) {
                if (rewind.hasNext(rewCursor)) {
                    const imgD = rewind.getNextImage(rewCursor);
                    @memcpy(@as([]u8, @ptrCast(&imageData)), imgD);
                    const bytes = rewind.getNext(&rewCursor);
                    var rewReader = std.Io.Reader.fixed(bytes);
                    try emulator.loadState(&rewReader); // FIXME: no need to load every time
                    // try std.Io.sleep(threaded.io(), std.Io.Duration.fromMilliseconds(@intFromFloat(1000 * (frame_time) * 2)), std.Io.Clock.real);
                }
            } else {
                rewCursor = rewind.getCursor();
                rewStarted = true;
            }

        } else {
            rewStarted = false;
           emulator.run_one_frame();
           if (!isEven) {
               _ = rewWriter.consumeAll();
               try emulator.saveState(&rewWriter);
               rewind.pushImageData(@ptrCast(&imageData));
               rewind.pushData(rewWriter.buffer);
            }
        }
        isEven = !isEven;

        // gl.useProgram(program);
        gl.bindVertexArray(vaos[0]);

        gl.clear(gl.COLOR_BUFFER_BIT);
        // gl.clearColor(0.118, 0.118, 0.180, 1.0);
        gl.clearColor(0.0, 0.0, 0.0, 1.0);

        gl.uniform4fv(colorLocation, 1, color[0..]);
        // const ortho = zm.orthographicLhGl(1920.0, 1080.0, 0.0, 1.0);
        // const scaling:f32 = @floatFromInt(@max(1, @as(usize, @intCast(fb_size[1])) / NES_HEIGHT));
        // std.debug.print("scaling: {d}\n", .{scaling});
        // const ortho = zm.orthographicOffCenterLhGl(0.0, @as(f32, @floatFromInt(NES_WIDTH)), 0.0, @as(f32, @floatFromInt(NES_HEIGHT)), 0.0, 1.0);
        const ortho = zm.orthographicOffCenterLhGl(0.0, @as(f32, @floatFromInt(fb_size[0])), 0.0, @as(f32, @floatFromInt(fb_size[1])), 0.0, 1.0);
        // const ortho = zm.orthographicOffCenterLhGl(0.0, 2.0 * @as(f32, @floatFromInt(NES_WIDTH)), 0.0, 2.0 * @as(f32, @floatFromInt(NES_HEIGHT)), 0.0, 1.0);
        gl.uniformMatrix4fv(projection_matrix, 1, 0, zm.arrNPtr(&ortho));
        gl.bindTexture(gl.TEXTURE_2D, textures[0]);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, NES_WIDTH, NES_HEIGHT, 0, gl.RGBA, gl.UNSIGNED_BYTE, &imageData);
        // gl.generateMipmap(gl.TEXTURE_2D);

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

        zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));
        if (textTimeout > 0) {
            zgui.getForegroundDrawList().addText(
                .{1.0, 1.0},
                zgui.colorConvertFloat3ToU32(.{1.0, 1.0, 1.0}), "{s}", .{text});
            textTimeout -=1;
        }

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

        zgui.backend.draw();

        window.swapBuffers();
    }
}

pub fn gen_triangles(vao: u32, positionAttrLocation: i32, outputSizeAttrLoc: i32, positionBuffer: u32, fb_size: [2]c_int) void {
    gl.bindVertexArray(vao);
    gl.enableVertexAttribArray(@bitCast(positionAttrLocation));

    // TODO: someday do it with glortho..
    gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer);
    // integer...
    // const scaling:f32 = @floatFromInt(@max(1, @as(usize, @intCast(fb_size[1])) / NES_HEIGHT));
    const scaling: f32 = if (videoOptions.integerScaling)
                             @floatFromInt(@max(1, @as(usize, @intCast(fb_size[1])) / NES_HEIGHT))
                         else 
                             @as(f32, @floatFromInt(fb_size[1])) / NES_HEIGHT;
    const left: f32 = (@as(f32, @floatFromInt(fb_size[0])) - scaling*NES_WIDTH) / 2.0;
    const top: f32 = (@as(f32, @floatFromInt(fb_size[1])) - scaling*NES_HEIGHT) / 2.0;
    gl.uniform2f(outputSizeAttrLoc, (scaling*NES_WIDTH), (scaling*NES_HEIGHT));

    // 6 vertices for each brick,
    // let's do the paddle first
    var data: [24]f32 = .{0} ** 24;
    data[0] = left;
    data[1] = top;
    data[2] = 0;
    data[3] = 1;

    data[4] = left + NES_WIDTH * scaling;
    data[5] = top;
    data[6] = 0;
    data[7] = 1;
    data[8] = left + NES_WIDTH * scaling;
    data[9] = top + NES_HEIGHT * scaling;
    data[10] = 0;
    data[11] = 1;

    data[12] = left + NES_WIDTH * scaling;
    data[13] = top + NES_HEIGHT * scaling;
    data[14] = 0;
    data[15] = 1;
    data[16] = left;
    data[17] = top + NES_HEIGHT * scaling;
    data[18] = 0;
    data[19] = 1;
    data[20] = left;
    data[21] = top;
    data[22] = 0;
    data[23] = 1;

    // const num_points: i32 = 6;

    // 4 * @as(isize , @intCast(data_idx))
    gl.bufferData(gl.ARRAY_BUFFER, 4 * data.len, &data, gl.STATIC_DRAW);

    const size = 4; // 4 components per iteration
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

    var data: [24]f32 = .{
        0, 0, 0, 0,
        1, 0, 0, 0,
        1, 1, 0, 0,
        1, 1, 0, 0,
        0, 1, 0, 0,
        0, 0, 0, 0,
    };

    // const num_points: i32 = 6;

    // 4 * @as(isize , @intCast(data_idx))
    gl.bufferData(gl.ARRAY_BUFFER, @sizeOf(f32) * data.len, &data, gl.STATIC_DRAW);

    const size = 4; // 4 components per iteration
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
pub fn onChangeFBSize(w: *glfw.Window, width:  c_int, height: c_int) callconv(.c) void {
    _ = &w;
    gl.viewport(0, 0, width, height);
}
