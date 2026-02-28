# gd4wlroots

## How to confirm operations

```bash
direnv allow # By nix-direnv
GODOT_PATH=$(which godot)
zig build -Dgodot-path=$GODOT_PATH

cd ./project
godot --path .
```
