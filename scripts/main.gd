extends Node3D
## Entry point. Builds the world, starts OpenXR when a headset is present
## (desktop mode otherwise), loads the topics and routes input to them.
## Command line (after "--"): --autotest, --benchmark, --benchmark-quick,
## --participant=ID, --no-log, --xr-preview (desktop view of the VR layout).

const TOPICS: Array[Dictionary] = [
	{"title": "Vector Fields", "script": "res://scripts/topics/vector_field_topic.gd"},
	{"title": "Divergence & Curl", "script": "res://scripts/topics/div_curl_topic.gd"},
	{"title": "Gradient", "script": "res://scripts/topics/gradient_topic.gd"},
	{"title": "Parametric Surfaces", "script": "res://scripts/topics/parametric_topic.gd"},
	{"title": "Solids of Revolution", "script": "res://scripts/topics/revolution_topic.gd"},
]
const BACKENDS: PackedStringArray = ["GPU (compute shader)", "CPU (GDScript baseline)"]
const PLOT_CENTER := Vector3(0.0, 1.25, 0.0)
const DESKTOP_START := Vector3(0.0, 1.6, 2.5)
const XR_START := Vector3(0.0, 0.0, 1.55)

var xr_interface: XRInterface
var xr_available := false
var xr_active := false
var current_topic: Topic
var current_index := -1
var backend := FieldEngine.Backend.GPU
var quality := 2
var animate := true
var time_speed := 1.0
var time := 0.0

var stats := StatsMonitor.new()
var session_log := SessionLog.new()
var benchmark := Benchmark.new()
var hud := Hud.new()
var locomotion := XRLocomotion.new()
var anchor := Node3D.new()
var topic_panel := ControlPanel3D.new()
var session_panel := ControlPanel3D.new()
var keypad := Keypad3D.new()
var desktop_camera := FreeFlyCamera.new()
var desktop_pointer := DesktopPointer.new()
var xr_origin := XROrigin3D.new()
var xr_camera := XRCamera3D.new()
var left_hand := XRHand.new()
var right_hand := XRHand.new()

var _board := Node3D.new()
var _board_label := Label3D.new()
var _wrist_label := Label3D.new()
var _ui_timer := 0.0
var _world_grab := {}
var _anchor_home := Transform3D(Basis.IDENTITY, PLOT_CENTER)
var _panels_forced := false


func _ready() -> void:
	InputSetup.register()
	_build_world()
	_build_rig()
	add_child(stats)
	stats.engines_provider = current_engines
	add_child(session_log)
	benchmark.main = self
	add_child(benchmark)
	benchmark.finished.connect(func(path: String) -> void:
		hud.toast("Benchmark saved: " + path, 6.0)
		session_log.log_event("benchmark_done", "", path))

	var titles := PackedStringArray()
	for t in TOPICS:
		titles.append(t.title)
	add_child(hud)
	hud.setup(titles)
	hud.topic_requested.connect(load_topic)
	hud.control_changed.connect(_on_control)
	hud.function_submitted.connect(submit_function)
	session_panel.control_changed.connect(_on_control)
	topic_panel.control_changed.connect(_on_control)
	keypad.submitted.connect(submit_function)

	xr_interface = XRServer.find_interface("OpenXR")
	xr_available = xr_interface != null and xr_interface.is_initialized()
	if OS.get_name() == "Android":
		quality = 1
	set_xr_mode(xr_available)
	if not xr_available:
		hud.toast("No VR headset detected: desktop mode (WASD + right mouse to look)", 4.0)
	if not GpuProgram.is_supported():
		backend = FieldEngine.Backend.CPU
		hud.toast("This renderer has no compute shaders: using the CPU path", 5.0)
	get_viewport().size_changed.connect(_on_resized)
	_on_resized()
	load_topic(0)

	var args := OS.get_cmdline_user_args()
	if args.has("--xr-preview"):
		_panels_forced = true
		_apply_panel_visibility()
	if args.has("--autotest"):
		var test: Node = load("res://tests/autotest.gd").new()
		test.set("main", self)
		add_child(test)
	elif args.has("--benchmark") or args.has("--benchmark-quick"):
		benchmark.quick = args.has("--benchmark-quick")
		benchmark.quit_when_done = true
		benchmark.run.call_deferred()


# --- World ---------------------------------------------------------------------------------

func _build_world() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.06, 0.08, 0.14)
	sky_mat.sky_horizon_color = Color(0.2, 0.24, 0.32)
	sky_mat.ground_bottom_color = Color(0.03, 0.03, 0.05)
	sky_mat.ground_horizon_color = Color(0.2, 0.24, 0.32)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.4
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, 35.0, 0.0)
	sun.light_energy = 1.0
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20.0, -140.0, 0.0)
	fill.light_energy = 0.35
	add_child(fill)
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(40, 40)
	var floor_mat := ShaderMaterial.new()
	floor_mat.shader = load("res://shaders/floor.gdshader")
	floor_mesh.material = floor_mat
	var floor_node := MeshInstance3D.new()
	floor_node.mesh = floor_mesh
	add_child(floor_node)

	anchor.name = "PlotAnchor"
	anchor.transform = _anchor_home
	add_child(anchor)

	topic_panel.name = "TopicPanel"
	topic_panel.transform = _facing(Vector3(-1.2, 1.85, 0.75), XR_START + Vector3(0, 1.4, 0))
	add_child(topic_panel)
	session_panel.name = "SessionPanel"
	session_panel.transform = _facing(Vector3(-1.55, 1.75, 1.6), XR_START + Vector3(0, 1.4, 0))
	add_child(session_panel)
	keypad.name = "Keypad"
	keypad.transform = _facing(Vector3(0.0, 1.05, 1.0), XR_START + Vector3(0, 1.6, 0.3))
	add_child(keypad)

	_board.name = "ReadoutBoard"
	_board.transform = _facing(Vector3(1.2, 1.75, 0.75), XR_START + Vector3(0, 1.4, 0))
	var board_mesh := BoxMesh.new()
	board_mesh.size = Vector3(0.78, 0.6, 0.01)
	board_mesh.material = MeshUtil.flat_material(Color(0.04, 0.05, 0.08, 0.85))
	var board_bg := MeshInstance3D.new()
	board_bg.mesh = board_mesh
	board_bg.position = Vector3(0.0, -0.25, -0.012)
	_board.add_child(board_bg)
	_board_label.font = MeshUtil.math_font()
	_board_label.font_size = 24
	_board_label.pixel_size = 0.001
	_board_label.outline_size = 0
	_board_label.render_priority = 2
	_board_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_board_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_board_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_board_label.width = 740
	_board_label.position = Vector3(-0.37, 0.03, 0.0)
	_board.add_child(_board_label)
	add_child(_board)


## Transform at `pos` whose +z faces `target` (labels and panels face +z).
static func _facing(pos: Vector3, target: Vector3) -> Transform3D:
	var dir := target - pos
	dir.y = 0.0
	return Transform3D(Basis.looking_at(-dir.normalized(), Vector3.UP), pos)


func _build_rig() -> void:
	desktop_camera.name = "DesktopCamera"
	desktop_camera.fov = 70.0
	add_child(desktop_camera)
	desktop_camera.reset_view(DESKTOP_START, PLOT_CENTER)
	desktop_pointer.camera = desktop_camera
	add_child(desktop_pointer)

	xr_origin.name = "XROrigin3D"
	xr_origin.position = XR_START
	add_child(xr_origin)
	xr_camera.name = "XRCamera3D"
	xr_camera.position = Vector3(0.0, 1.6, 0.0)
	xr_camera.near = 0.05
	xr_origin.add_child(xr_camera)
	for hand: XRHand in [left_hand, right_hand]:
		hand.tracker = &"left_hand" if hand == left_hand else &"right_hand"
		hand.pose = &"aim"
		hand.name = "LeftHand" if hand == left_hand else "RightHand"
		xr_origin.add_child(hand)
		hand.grip_changed.connect(_on_grip)
		hand.pointer.grabbed.connect(_on_grabbed)
		hand.pointer.released.connect(_on_released)
		hand.button_pressed.connect(_on_xr_button.bind(hand))
	desktop_pointer.pointer.grabbed.connect(_on_grabbed)
	desktop_pointer.pointer.released.connect(_on_released)
	_wrist_label.font = MeshUtil.math_font()
	_wrist_label.font_size = 22
	_wrist_label.pixel_size = 0.0008
	_wrist_label.outline_size = 6
	_wrist_label.position = Vector3(0.0, 0.06, 0.05)
	_wrist_label.rotation_degrees = Vector3(-50.0, 0.0, 0.0)
	_wrist_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	left_hand.add_child(_wrist_label)
	locomotion.name = "Locomotion"
	add_child(locomotion)
	locomotion.setup(xr_origin, xr_camera, left_hand, right_hand)


func set_xr_mode(enable: bool) -> void:
	if enable and not xr_available:
		hud.toast("No OpenXR runtime: staying in desktop mode", 3.0)
		enable = false
	xr_active = enable
	get_viewport().use_xr = enable
	xr_camera.current = enable
	desktop_camera.current = not enable
	desktop_camera.enabled = not enable
	desktop_pointer.enabled = not enable
	left_hand.enabled = enable
	right_hand.enabled = enable
	locomotion.enabled = enable
	if enable and xr_interface is OpenXRInterface:
		var openxr := xr_interface as OpenXRInterface
		var rates := openxr.get_available_display_refresh_rates()
		if rates.has(90.0):
			openxr.display_refresh_rate = 90.0
		stats.target_hz = openxr.display_refresh_rate if openxr.display_refresh_rate > 0.0 else 90.0
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	else:
		stats.target_hz = 90.0
	_apply_panel_visibility()


func _apply_panel_visibility() -> void:
	var show_3d := xr_active or _panels_forced
	topic_panel.visible = show_3d
	session_panel.visible = show_3d
	_board.visible = show_3d
	hud.set_panels_visible(not xr_active and not _panels_forced)
	_center_view()
	if not show_3d:
		keypad.visible = false


# --- Topics ----------------------------------------------------------------------------------

func load_topic(index: int) -> void:
	if index < 0 or index >= TOPICS.size():
		return
	if index == current_index and current_topic:
		return
	desktop_pointer.pointer.release()
	left_hand.pointer.release()
	right_hand.pointer.release()
	if current_topic:
		anchor.remove_child(current_topic)
		current_topic.queue_free()
	var topic: Topic = load(TOPICS[index].script).new()
	topic.name = "Topic"
	topic.quality = quality
	topic.backend = backend
	topic.time = time
	current_topic = topic
	current_index = index
	anchor.add_child(topic)
	topic.control_value_changed.connect(_on_topic_value_changed)
	topic.function_text_changed.connect(func(text: String) -> void:
		hud.set_function_text(text)
		if keypad.visible:
			keypad.open(topic.get_function_spec().label, text, topic.get_function_spec().variables))
	topic.message.connect(func(text: String, is_error: bool) -> void:
		hud.toast(text, 5.0 if is_error else 3.0))
	_rebuild_controls()
	hud.set_topic(index)
	hud.set_function_spec(topic.get_function_spec())
	keypad.visible = false
	session_log.log_event("topic", topic.topic_title)


func current_engines() -> Array[FieldEngine]:
	return current_topic.engines() if current_topic else ([] as Array[FieldEngine])


func _global_controls() -> Array:
	var titles := PackedStringArray()
	for t in TOPICS:
		titles.append(t.title)
	return [
		ControlSpec.choice("topic", "Topic", titles, maxi(current_index, 0)),
		ControlSpec.choice("backend", "Compute on", BACKENDS, backend),
		ControlSpec.choice("quality", "Resolution", Topic.QUALITY_NAMES, quality),
		ControlSpec.toggle("animate", "Animate time t", animate),
		ControlSpec.slider("time_speed", "Time speed", 0.0, 3.0, 0.1, time_speed, "%.1f"),
		ControlSpec.button("edit", "Type a function…"),
		ControlSpec.button("benchmark", "Run benchmark (GPU vs CPU)"),
		ControlSpec.button("reset", "Reset plot position"),
	]


func _rebuild_controls() -> void:
	var global := _global_controls()
	var topic_specs := current_topic.get_controls() if current_topic else []
	hud.build_global(global)
	hud.build_topic(topic_specs)
	session_panel.build("VRFields", global)
	topic_panel.build(current_topic.topic_title if current_topic else "", topic_specs)


func _on_control(id: String, value: Variant) -> void:
	match id:
		"topic":
			load_topic(value)
		"backend":
			set_backend(value)
		"quality":
			set_quality(value)
		"animate":
			animate = value
		"time_speed":
			time_speed = value
		"edit":
			open_editor()
		"benchmark":
			benchmark.run()
		"reset":
			reset_view()
		_:
			if current_topic:
				current_topic.on_control(id, value)
	# Keep the other UI in sync.
	hud.set_value(id, value)
	session_panel.set_value(id, value)
	topic_panel.set_value(id, value)
	if id != "time_speed" and not (value is float and id in ["a", "b"]):
		session_log.log_event("control", current_topic.topic_title if current_topic else "", "%s=%s" % [id, value])


func _on_topic_value_changed(id: String, value: Variant) -> void:
	hud.set_value(id, value)
	topic_panel.set_value(id, value)
	if id == "preset":
		session_log.log_event("preset", current_topic.topic_title, current_topic.preset_names()[value])


func set_backend(value: int) -> void:
	if value == FieldEngine.Backend.GPU and not GpuProgram.is_supported():
		value = FieldEngine.Backend.CPU
	backend = value
	if current_topic:
		current_topic.set_backend(value)
	hud.set_value("backend", value)
	session_panel.set_value("backend", value)
	if value == FieldEngine.Backend.CPU and not benchmark.running:
		hud.toast("CPU baseline: the same functions evaluated in GDScript. Expect low FPS at high resolution.", 4.0)


func set_quality(value: int) -> void:
	quality = clampi(value, 0, 3)
	if current_topic:
		current_topic.set_quality(quality)
	hud.set_value("quality", quality)
	session_panel.set_value("quality", quality)


func submit_function(text: String) -> void:
	if not current_topic:
		return
	var error := current_topic.set_function(text)
	hud.show_function_result(error)
	if error.is_empty():
		hud.set_function_text(text)
		keypad.set_status("✓ Plotted", Color(0.5, 1.0, 0.6))
	else:
		keypad.set_status("✗ " + error, Color(1.0, 0.5, 0.45))
	session_log.log_event("function", current_topic.topic_title, "%s -> %s" % [text, "ok" if error.is_empty() else error])


func open_editor() -> void:
	if not current_topic:
		return
	var spec := current_topic.get_function_spec()
	if xr_active or _panels_forced:
		keypad.open(spec.label, spec.text, spec.variables)
	else:
		hud.focus_function()


func reset_view() -> void:
	anchor.transform = _anchor_home
	if xr_active:
		locomotion.reset()
	else:
		desktop_camera.reset_view(DESKTOP_START, PLOT_CENTER)


# --- Per frame --------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if animate:
		time += delta * time_speed
	if current_topic:
		current_topic.time = time
	hud.set_crosshair(not xr_active and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED,
			desktop_pointer.pointer.is_hovering())
	desktop_camera.typing = hud.is_typing()
	_update_world_grab()
	if current_topic and not hud.is_typing():
		var axis := Input.get_vector("nudge_left", "nudge_right", "nudge_down", "nudge_up")
		if xr_active and (left_hand.grip_pressed or right_hand.grip_pressed) and _world_grab.is_empty():
			axis += right_hand.get_vector2("primary")
		if axis.length_squared() > 0.01:
			current_topic.handle_nudge(axis.limit_length(1.0), delta)
	_ui_timer -= delta
	if _ui_timer <= 0.0:
		_ui_timer = 0.2
		_refresh_text()


func _refresh_text() -> void:
	var s := stats.live()
	var lines := PackedStringArray([
		"%.0f FPS   frame %.2f ms (p99 %.1f)   budget %.1f ms" % [s.fps, s.mean_ms, s.p99_ms, 1000.0 / stats.target_hz],
		"GPU frame %.2f ms   compute %.3f ms" % [s.gpu_ms, s.compute_ms],
		"CPU field update %.2f ms   over budget %.0f%%" % [s.update_ms, s.over_budget_pct],
		"Backend: %s" % BACKENDS[backend],
	])
	if current_topic:
		var work := current_topic.workload()
		var parts := PackedStringArray()
		for k: String in work:
			parts.append("%s %s" % [_thousands(work[k]), k])
		lines.append(", ".join(parts))
	var text := "\n".join(lines)
	hud.set_stats(("Mode: %s\n" % ("VR (OpenXR)" if xr_active else "Desktop")) + text)
	_wrist_label.text = text
	if current_topic:
		hud.set_readout(current_topic.readout)
		_board_label.text = current_topic.topic_title + "\n\n" + current_topic.readout + "\n\n" + current_topic.get_hint()


static func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(-3)
	return s + out


# --- VR world grab: grip on empty space moves the plot; both grips scale/turn it ------------------

func _on_grip(hand: XRHand, pressed: bool) -> void:
	if pressed:
		_world_grab[hand] = true
	else:
		_world_grab.erase(hand)
	_world_grab_start()


func _world_grab_start() -> void:
	_world_grab_state = {}
	var hands := _world_grab.keys()
	if hands.size() == 1:
		var h: XRHand = hands[0]
		_world_grab_state = {"mode": 1, "hand": h, "offset": h.global_transform.affine_inverse() * anchor.global_transform}
	elif hands.size() == 2:
		var a: XRHand = hands[0]
		var b: XRHand = hands[1]
		_world_grab_state = {"mode": 2, "a": a, "b": b, "start_anchor": anchor.global_transform,
				"start_dist": a.global_position.distance_to(b.global_position),
				"start_mid": (a.global_position + b.global_position) * 0.5,
				"start_angle": _yaw_between(a.global_position, b.global_position)}


var _world_grab_state := {}


static func _yaw_between(a: Vector3, b: Vector3) -> float:
	return atan2(b.x - a.x, b.z - a.z)


func _update_world_grab() -> void:
	if _world_grab_state.is_empty():
		return
	if _world_grab_state.mode == 1:
		var h: XRHand = _world_grab_state.hand
		var target: Transform3D = h.global_transform * _world_grab_state.offset
		# Translation and yaw only: tilting the plot is disorienting.
		var yaw := target.basis.get_euler().y
		anchor.global_transform = Transform3D(Basis(Vector3.UP, yaw).scaled(anchor.global_basis.get_scale()), target.origin)
	else:
		var a: XRHand = _world_grab_state.a
		var b: XRHand = _world_grab_state.b
		var dist := a.global_position.distance_to(b.global_position)
		var factor := clampf(dist / maxf(_world_grab_state.start_dist, 0.01), 0.2, 5.0)
		var turn: float = _yaw_between(a.global_position, b.global_position) - _world_grab_state.start_angle
		var start: Transform3D = _world_grab_state.start_anchor
		var mid := (a.global_position + b.global_position) * 0.5
		var scale_now := clampf(start.basis.get_scale().x * factor, 0.2, 4.0)
		var basis := Basis(Vector3.UP, start.basis.get_euler().y + turn).scaled(Vector3.ONE * scale_now)
		var rel: Vector3 = start.origin - _world_grab_state.start_mid
		rel = Basis(Vector3.UP, turn) * rel * (scale_now / start.basis.get_scale().x)
		anchor.global_transform = Transform3D(basis, mid + rel)


# --- Input ---------------------------------------------------------------------------------------

func _on_grabbed(target: Node) -> void:
	if target is Grabbable:
		session_log.grab_started(current_topic.topic_title if current_topic else "", target)


func _on_released(target: Node) -> void:
	if target is Grabbable:
		session_log.grab_ended(current_topic.topic_title if current_topic else "", target)


func _on_xr_button(action: String, hand: XRHand) -> void:
	if not xr_active or not current_topic:
		return
	if action == "ax_button":
		current_topic.handle_action()
	elif action == "menu_button":
		open_editor()
	elif action == "primary_click" and hand == right_hand:
		set_backend(FieldEngine.Backend.CPU if backend == FieldEngine.Backend.GPU else FieldEngine.Backend.GPU)


func _unhandled_input(event: InputEvent) -> void:
	var wheel := event as InputEventMouseButton
	if wheel and wheel.pressed and current_topic and not xr_active:
		if wheel.button_index == MOUSE_BUTTON_WHEEL_UP:
			current_topic.handle_scroll(1.0)
		elif wheel.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			current_topic.handle_scroll(-1.0)
		return
	if event.is_echo() or hud.is_typing():
		return
	if event.is_action_pressed("toggle_xr"):
		set_xr_mode(not xr_active)
	elif event.is_action_pressed("toggle_help"):
		hud.toggle_help()
	elif event.is_action_pressed("toggle_hud"):
		hud.set_panels_visible(not hud.panels_visible())
		_center_view()
	elif event.is_action_pressed("toggle_panel"):
		_panels_forced = not _panels_forced
		_apply_panel_visibility()
	elif event.is_action_pressed("toggle_backend"):
		set_backend(FieldEngine.Backend.CPU if backend == FieldEngine.Backend.GPU else FieldEngine.Backend.GPU)
	elif event.is_action_pressed("reset_view"):
		reset_view()
	elif event.is_action_pressed("screenshot"):
		var path: String = await take_screenshot()
		hud.toast("Screenshot saved: " + path)
	elif event.is_action_pressed("topic_action") and current_topic:
		current_topic.handle_action()
	else:
		for i in TOPICS.size():
			if event.is_action_pressed("topic_%d" % (i + 1)):
				load_topic(i)
				return


func _on_resized() -> void:
	var size := get_viewport().get_visible_rect().size
	# Tiling window managers often give a tall window: keep the horizontal FOV then.
	desktop_camera.keep_aspect = Camera3D.KEEP_WIDTH if size.x < size.y * 1.3 else Camera3D.KEEP_HEIGHT
	_center_view()


## Shifts the desktop camera sideways so the plot sits in the middle of the
## part of the window the control column does not cover.
func _center_view() -> void:
	var size := get_viewport().get_visible_rect().size
	if size.x <= 0.0:
		return
	var covered := hud.right_width() if hud.get_parent() else 0.0
	var aspect := size.x / size.y
	var tan_half := tan(deg_to_rad(desktop_camera.fov * 0.5))
	var tan_h := tan_half if desktop_camera.keep_aspect == Camera3D.KEEP_WIDTH else tan_half * aspect
	var distance := DESKTOP_START.distance_to(PLOT_CENTER)
	desktop_camera.h_offset = (covered / size.x) * distance * tan_h


## Saves the current frame to res://screenshots (user:// in exported builds).
func take_screenshot(file_name: String = "") -> String:
	await RenderingServer.frame_post_draw
	var dir := "user://screenshots" if OS.has_feature("template") else "res://screenshots"
	DirAccess.make_dir_recursive_absolute(dir)
	if file_name.is_empty():
		file_name = "vrfields_%s.png" % Time.get_datetime_string_from_system().replace(":", "-")
	var path := ProjectSettings.globalize_path(dir.path_join(file_name))
	get_viewport().get_texture().get_image().save_png(path)
	return path
