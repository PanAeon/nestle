with import <nixpkgs> {};

mkShell {
  # packages = [ zls ];
  LD_LIBRARY_PATH="${libpulseaudio}/lib:${wayland}/lib:${wayland-scanner}/lib:${wayland-protocols}/lib:${libdecor}/lib:${libGL}/lib:${libxkbcommon}/lib";
  buildInputs = [
        #dawn
    xorg.libX11
    # SDL2
    # SDL2_ttf
    # SDL2_image
    wayland
    libxkbcommon
    libGL
    libpulseaudio
    # openal
        # glfw
        #cmake
        #    gcc # or clang, depending on your compiler
        #    sdl3
    # zlib
    # libGL
    # boost177
    # SDL_compat
    # SDL_sound
    # SDL_image
    # libvorbis
    # SDL_ttf
    # glew
    # openal
    # ffmpeg
    # gtk2
    # pango
    # cairo
    # glib
    # harfbuzz
    # gdk-pixbuf
    # atk
    # freetype
    # fontconfig
    # Add other build tools or libraries as needed
  ];
      # PKG_CONFIG_PATH="${gtk2.dev}/lib/pkgconfig:${pango.dev}/lib/pkgconfig:${glib.dev}/lib/pkgconfig:${harfbuzz.dev}/lib/pkgconfig:${cairo.dev}/lib/pkgconfig:${gdk-pixbuf.dev}/lib/pkgconfig:${atk.dev}/lib/pkgconfig:${freetype.dev}/lib/pkgconfig:${fontconfig.dev}/lib/pkgconfig";
}

