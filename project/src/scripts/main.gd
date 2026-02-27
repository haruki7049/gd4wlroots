extends WaylandCompositor

var _printed := false

func _ready() -> void:
	init_compositor()
	set_process(true)
	print("_ready done, socket=", get_socket_name())

	# 背景を明るい青にして foot と区別する
	RenderingServer.set_default_clear_color(Color(0.3, 0.5, 0.8))

func _process(delta: float) -> void:
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
				sp.centered = false
				sp.position = Vector2(0, 0)
				var tex := sp.texture
				if tex:
					print("  ", child.name, " tex_size=", tex.get_size(),
						" visible=", sp.visible, " pos=", sp.position)
