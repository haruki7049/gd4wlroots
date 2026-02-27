extends WaylandCompositor

var _printed := false

func _ready() -> void:
	# Zig 側の初期化を明示的に呼ぶ
	init_compositor()
	set_process(true)
	print("_ready done, socket=", get_socket_name())

func _process(delta: float) -> void:
	# Wayland イベントループを回す
	poll_wayland()

	if not _printed:
		var socket := get_socket_name()
		if socket != "":
			print("=== Wayland socket: ", socket, " ===")
			_printed = true

	var count := get_child_count()
	if count > 0:
		for i in count:
			var child := get_child(i)
			if child is Sprite2D:
				var sp := child as Sprite2D
				var tex := sp.texture
				if tex:
					print("  ", child.name, " tex_size=", tex.get_size(),
						" visible=", sp.visible, " pos=", sp.position)
