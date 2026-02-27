{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShell {
  nativeBuildInputs = [
    # Compiler
    pkgs.zig_0_15
    pkgs.pkg-config

    # Runtime
    pkgs.godotPackages_4_6.godot

    # LSP
    pkgs.nil
    pkgs.zls
  ];

  buildInputs = [
    pkgs.wlroots
    pkgs.wayland
    pkgs.pixman
    pkgs.libxkbcommon
  ];
}
