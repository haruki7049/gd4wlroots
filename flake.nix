{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    systems.url = "github:nix-systems/default";
    flake-compat.url = "github:edolstra/flake-compat";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;
      imports = [
        inputs.treefmt-nix.flakeModule
      ];

      perSystem =
        { pkgs, lib, ... }:
        {
          treefmt = {
            projectRootFile = ".git/config";

            # Nix
            programs.nixfmt.enable = true;

            # Zig
            programs.zig.enable = true;
            settings.formatter.zig.command = lib.getExe pkgs.zig_0_15;

            # GitHub Actions
            programs.actionlint.enable = true;

            # Markdown
            programs.mdformat.enable = true;
          };

          devShells.default = pkgs.mkShell {
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
              pkgs.wayland-protocols # provides stable/xdg-shell/xdg-shell.xml
              pkgs.pixman
              pkgs.libxkbcommon
            ];

            # Expose the wayland-protocols XML directory to build.zig via an env var.
            env = {
              WAYLAND_PROTOCOLS = "${pkgs.wayland-protocols}/share/wayland-protocols";
            };
          };
        };
    };
}
