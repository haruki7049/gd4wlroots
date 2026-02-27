{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShell {
  nativeBuildInputs = [
    # Compiler
    pkgs.zig_0_15
    pkgs.pkg-config

    # wayland-scanner (generates xdg-shell-protocol.h and friends from XML)
    pkgs.wayland
    pkgs.wayland-scanner

    # Runtime
    pkgs.godotPackages_4_6.godot

    # LSP
    pkgs.nil
    pkgs.zls
  ];

  buildInputs = [
    pkgs.wlroots
    pkgs.wayland
    pkgs.wayland-protocols  # provides stable/xdg-shell/xdg-shell.xml
    pkgs.pixman
    pkgs.libxkbcommon
  ];

  # Expose the wayland-protocols XML directory to build.zig via an env var.
  WAYLAND_PROTOCOLS = "${pkgs.wayland-protocols}/share/wayland-protocols";
}
