extends Node
## Windowed self-test:  godot --path . -- --autotest
## 1. GPU = CPU: reads every compute-shader output back and compares it with the
##    CPU evaluation of the same expressions, texel by texel.
## 2. The calculus: numerical answers against exact ones (div, curl, Gauss,
##    Stokes, gradients, curvature, volumes).
## 3. The app: real mouse/keyboard events on the HUD, the 3D panels, the probes.
## Saves screenshots to res://screenshots and quits with the number of failures.

var main: Node3D
var _checks := 0
var _failures := 0


func _ready() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("[TEST] %s  %s" % ["PASS" if ok else "FAIL", what])


static func _sci(x: float) -> String:
	return String.num_scientific(x) if absf(x) < 1e-3 and x != 0.0 else "%.4f" % x


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _read(engine: FieldEngine, name: String) -> PackedByteArray:
	var result := []
	engine.program.read_back(name, func(d: PackedByteArray) -> void: result.append(d))
	while result.is_empty():
		await get_tree().process_frame
	return result[0]


func _shot(file_name: String) -> void:
	await _frames(2)
	var path: String = await main.take_screenshot(file_name)
	print("[TEST] screenshot  ", path)


func _mouse_button(button: MouseButton, pressed: bool, pos: Vector2) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = pressed
	e.position = pos
	e.global_position = pos
	Input.parse_input_event(e)


func _mouse_move(pos: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.global_position = pos
	Input.parse_input_event(e)


func _click(pos: Vector2) -> void:
	_mouse_move(pos)
	await _frames(2)
	_mouse_button(MOUSE_BUTTON_LEFT, true, pos)
	await _frames(2)
	_mouse_button(MOUSE_BUTTON_LEFT, false, pos)
	await _frames(2)


func _key(physical: Key) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.physical_keycode = physical
		e.keycode = physical
		e.pressed = pressed
		Input.parse_input_event(e)
		await _frames(1)


func _type(text: String) -> void:
	for c in text:
		var e := InputEventKey.new()
		e.pressed = true
		e.unicode = c.unicode_at(0)
		Input.parse_input_event(e)
		var up := e.duplicate()
		up.pressed = false
		Input.parse_input_event(up)
		await _frames(1)
	await _key(KEY_ENTER)
	await _frames(3)


func _screen(world: Vector3) -> Vector2:
	return main.desktop_camera.unproject_position(world)


func _run() -> void:
	await _frames(10)
	print("[TEST] info  GPU: %s  renderer: %s  window %s" % [RenderingServer.get_video_adapter_name(),
			RenderingServer.get_current_rendering_method(), main.get_viewport().get_visible_rect().size])
	_check(GpuProgram.is_supported(), "compute shaders available (RenderingDevice)")
	await _test_vector_engine()
	await _test_surface_engines()
	await _test_vector_topic_ui()
	await _test_div_curl_topic()
	await _test_gradient_topic()
	await _test_parametric_topic()
	await _test_revolution_topic()
	await _test_backend_and_panels()
	await _test_benchmark_quick()
	_check(FileAccess.file_exists(main.session_log.path), "session log written: " + ProjectSettings.globalize_path(main.session_log.path))
	print("[TEST] DONE  %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(_failures)


# --- 1. GPU output == CPU evaluation ----------------------------------------------------------

func _test_vector_engine() -> void:
	var e := VectorFieldEngine.new()
	e.grid_n = 10
	e.volume_m = 16
	e.volume_enabled = true
	e.particle_count = 1024
	e.lines_enabled = true
	e.line_seeds = 4
	e.line_steps = 60
	e.param_a = 0.7
	e.param_b = -1.3
	e.t = 0.9
	e.set_seeds(PackedVector3Array([Vector3(1, 0, 0), Vector3(0, 1.5, 0.3), Vector3(-0.5, 0.2, -1), Vector3(0.3, -0.4, 0.8)]))
	var fields := [
		"(-y, x, 0)",
		"(x^3 - y, a sin(t z), b exp(-x^2))",
		"(sqrt(x), 1 / x, ln(y))",            # NaN and inf where undefined -> 0 on both paths
		"((-x)^3, (-y)^2.5, abs(z)^0.5)",     # negative bases with whole and fractional powers
		"(sin(z) + cos(y), sin(x) + cos(z), sin(y) + cos(x))",
	]
	for text: String in fields:
		_check(e.set_field(text).is_empty(), "field compiles: " + text)
		for i in 3:
			e.update(1.0 / 60.0)
			await _frames(1)
		_check(e.program.status == GpuProgram.Status.READY, "GPU shader built for " + text)
		var data := (await _read(e, "field")).to_float32_array()
		var n := e.grid_n
		var worst := 0.0
		var scale := 1e-6
		for k in n:
			for j in n:
				for i in n:
					var o := ((j + n * k) * n + i) * 4
					var cpu := e.field(e.grid_point(i, j, k))
					worst = maxf(worst, (Vector3(data[o], data[o + 1], data[o + 2]) - cpu).length())
					scale = maxf(scale, cpu.length())
		_check(worst <= 1e-5 * maxf(scale, 1.0), "GPU field = CPU at all %d points (max diff %s, |F| ≤ %.2f)" % [n * n * n, _sci(worst), scale])

	# div / curl volume (half floats on the GPU: compare to 0.3 % of the max).
	e.set_field("(x y - z^2, sin(y) z, x + y^3)")
	for i in 3:
		e.update(1.0 / 60.0)
		await _frames(1)
	var vol := await _read(e, "volume")
	var m := e.volume_m
	var s := 2.0 * e.extent / (m - 1)
	var worst := 0.0
	var top := 1e-6
	for k in range(0, m, 3):
		for j in range(0, m, 3):
			for i in range(0, m, 3):
				var o := ((k * m + j) * m + i) * 8
				var dc := e.div_curl(Vector3(-e.extent + s * i, -e.extent + s * j, -e.extent + s * k))
				var gpu := Vector4(vol.decode_half(o), vol.decode_half(o + 2), vol.decode_half(o + 4), vol.decode_half(o + 6))
				var c: Vector3 = dc[1]
				worst = maxf(worst, (gpu - Vector4(dc[0], c.x, c.y, c.z)).length())
				top = maxf(top, Vector4(dc[0], c.x, c.y, c.z).length())
	_check(worst < 3e-3 * top, "GPU div/curl volume = CPU (max diff %s of %.2f)" % [_sci(worst), top])
	# Exact values: F = (xy - z², z sin y, x + y³): div = y + z cos y, curl = (3y² - sin y, -2z - 1, -x).
	var p := Vector3(0.4, -0.7, 1.1)
	var dc := e.div_curl(p)
	var exact_div := p.y + p.z * cos(p.y)
	var exact_curl := Vector3(3.0 * p.y * p.y - sin(p.y), -2.0 * p.z - 1.0, -p.x)
	_check(absf(dc[0] - exact_div) < 1e-4 and (dc[1] - exact_curl).length() < 1e-4,
			"div F = %.5f (exact %.5f), curl F = %s (exact %s)" % [dc[0], exact_div, Topic.fmt3(dc[1], 4), Topic.fmt3(exact_curl, 4)])

	# Field lines of a rotation are circles; particles stay inside the box.
	e.set_field("(-y, x, 0)")
	for i in 30:
		e.update(1.0 / 60.0)
		await _frames(1)
	var lines := (await _read(e, "lines")).to_float32_array()
	var w := e.line_steps * 2 + 1
	var drift := 0.0
	for sd in e.line_seeds:
		var seed: Vector3 = e.seeds[sd]
		var r0 := Vector2(seed.x, seed.y).length()
		for c in w:
			var o := (sd * w + c) * 4
			drift = maxf(drift, absf(Vector2(lines[o], lines[o + 1]).length() - r0))
	_check(drift < 1e-4, "RK4 field lines of (-y, x, 0) stay on their circles (max radius drift %s)" % _sci(drift))
	var parts := (await _read(e, "particle_buf")).to_float32_array()
	var inside := true
	var alive := 0
	for i in e.particle_count:
		var pos := Vector3(parts[i * 8], parts[i * 8 + 1], parts[i * 8 + 2])
		if parts[i * 8 + 3] > 0.0:
			alive += 1
			inside = inside and absf(pos.x) <= e.extent and absf(pos.y) <= e.extent and absf(pos.z) <= e.extent
	_check(inside and alive > e.particle_count * 0.9, "GPU particles inside the box, %d/%d alive" % [alive, e.particle_count])
	# One RK4 step keeps the radius of a rotation: compare consecutive frames.
	var before := (await _read(e, "particle_buf")).to_float32_array()
	e.update(1.0 / 60.0)
	await _frames(1)
	var after := (await _read(e, "particle_buf")).to_float32_array()
	var radius_change := 0.0
	var moved := 0
	for i in e.particle_count:
		if after[i * 8 + 3] > 0.0 and after[i * 8 + 3] < before[i * 8 + 3]:
			var r_b := Vector2(before[i * 8], before[i * 8 + 1]).length()
			var r_a := Vector2(after[i * 8], after[i * 8 + 1]).length()
			radius_change = maxf(radius_change, absf(r_a - r_b))
			moved += 1
	_check(moved > 100 and radius_change < 1e-5, "particles circle the axis (%d moved, max radius change %s)" % [moved, _sci(radius_change)])

	# Stats: max |F| of the rotation on the grid = |(2, 2)| = 2√2.
	await _wait(0.3)
	e.update(0.3)
	await _frames(3)
	_check(absf(e.max_magnitude - 2.0 * sqrt(2.0)) < 1e-4, "GPU reduction: max |F| = %.5f (2√2 = %.5f)" % [e.max_magnitude, 2.0 * sqrt(2.0)])

	# CPU baseline produces the same layout.
	e.set_backend(FieldEngine.Backend.CPU)
	e.dirty = true
	e.update(1.0 / 60.0)
	var cpu_tex: Texture2D = e.get_output("field")
	var img := cpu_tex.get_image()
	var probe := e.grid_point(3, 7, 2)
	var texel := img.get_pixel(3, 7 + e.grid_n * 2)
	_check(cpu_tex is ImageTexture and Vector3(texel.r, texel.g, texel.b).is_equal_approx(e.field(probe)),
			"CPU baseline writes the same texture layout (%.1f ms for %d points + %d particles)" % [e.cpu_update_ms, e.grid_n ** 3, e.particle_count])
	e.free_gpu()


func _test_surface_engines() -> void:
	# Scalar surface: f and its gradient.
	var s := ScalarSurfaceEngine.new()
	s.resolution = 64
	s.param_a = 1.5
	_check(s.set_function("a x^2 - y^3 + sin(x y)").is_empty(), "surface compiles")
	for i in 3:
		s.update(1.0 / 60.0)
		await _frames(1)
	var d := (await _read(s, "surface")).to_float32_array()
	var worst := 0.0
	for j in range(0, 64, 3):
		for i in range(0, 64, 3):
			var o := (j * 64 + i) * 4
			var xy := s.sample_xy(i, j)
			var g := s.gradient(xy.x, xy.y)
			worst = maxf(worst, maxf(absf(d[o] - s.f(xy.x, xy.y)), Vector2(d[o + 1] - g.x, d[o + 2] - g.y).length()))
	_check(worst < 2e-3, "GPU surface f and ∇f = CPU (max diff %s)" % _sci(worst))
	var xy0 := Vector2(0.7, -0.4)
	var exact := Vector2(2.0 * 1.5 * xy0.x + xy0.y * cos(xy0.x * xy0.y), -3.0 * xy0.y * xy0.y + xy0.x * cos(xy0.x * xy0.y))
	_check((s.gradient(xy0.x, xy0.y) - exact).length() < 1e-5, "∇f by central differences = exact (%s)" % exact)
	s.free_gpu()

	# Parametric sphere: |r| = a and K = 1/a².
	var pe := ParametricEngine.new()
	pe.resolution = 48
	pe.param_a = 1.5
	_check(pe.set_surface("(a cos(u) sin(v), a sin(u) sin(v), a cos(v))", 0.0, TAU, 0.0, PI).is_empty(), "parametric compiles")
	for i in 3:
		pe.update(1.0 / 60.0)
		await _frames(1)
	var pd := (await _read(pe, "surface")).to_float32_array()
	var r_err := 0.0
	var k_err := 0.0
	for j in range(6, 42):
		for i in 48:
			var o := (j * 48 + i) * 4
			r_err = maxf(r_err, absf(Vector3(pd[o], pd[o + 1], pd[o + 2]).length() - 1.5))
			k_err = maxf(k_err, absf(pd[o + 3] - 1.0 / 2.25))
	_check(r_err < 1e-5, "GPU sphere points have |r| = a (max err %s)" % _sci(r_err))
	_check(k_err < 0.01, "GPU Gaussian curvature of the sphere = 1/a² = 0.444 (max err %.4f, float32)" % k_err)
	var fr := pe.frame(1.0, 1.2)
	_check(absf(fr.K - 1.0 / 2.25) < 1e-3 and absf(absf(fr.H) - 1.0 / 1.5) < 1e-3, "CPU K = %.4f, |H| = %.4f (sphere: 1/a², 1/a)" % [fr.K, absf(fr.H)])
	pe.set_surface("((2 + cos(v)) cos(u), (2 + cos(v)) sin(u), sin(v))", 0.0, TAU, 0.0, TAU)
	var k_out: float = pe.frame(0.3, 0.0).K
	var k_in: float = pe.frame(0.3, PI).K
	_check(absf(k_out - 1.0 / 3.0) < 1e-3 and absf(k_in + 1.0) < 1e-3, "torus: K = %.4f outside (1/3), %.4f inside (−1)" % [k_out, k_in])
	pe.free_gpu()

	# Profile and volumes.
	var pr := ProfileEngine.new()
	pr.resolution = 128
	pr.set_profile("sqrt(4 - (x - 2)^2)", "0", 0.0, 4.0)
	for i in 3:
		pr.update(1.0 / 60.0)
		await _frames(1)
	var prd := (await _read(pr, "profile")).to_float32_array()
	var p_err := 0.0
	for i in 128:
		var x := lerpf(0.0, 4.0, i / 127.0)
		p_err = maxf(p_err, absf(prd[i * 4] - pr.outer_radius(x)))
	_check(p_err < 1e-4, "GPU profile = CPU (max diff %s)" % _sci(p_err))
	var cases := [
		["sqrt(4 - (x - 2)^2)", "0", 0.0, 4.0, 32.0 * PI / 3.0, "sphere 32π/3"],
		["sqrt(x)", "0", 0.0, 4.0, 8.0 * PI, "paraboloid 8π"],
		["sqrt(x)", "x/2", 0.0, 4.0, 8.0 * PI / 3.0, "washer 8π/3"],
		["1.5 + sqrt(0.25 - (x - 2)^2)", "1.5 - sqrt(0.25 - (x - 2)^2)", 1.5, 2.5, 2.0 * PI * PI * 1.5 * 0.25, "torus 2π²Rr²"],
		["1/x", "0", 1.0, 8.0, 7.0 * PI / 8.0, "Gabriel's horn 7π/8"],
	]
	for c in cases:
		pr.set_profile(c[0], c[1], c[2], c[3])
		var v := pr.volume_to(c[3])
		_check(absf(v - c[4]) < 2e-3 * c[4], "volume of %s: %.5f vs %.5f" % [c[5], v, c[4]])
	# Sphere: A(x) is quadratic, so the midpoint sum has an O(1/n²) error.
	pr.set_profile("sqrt(4 - (x - 2)^2)", "0", 0.0, 4.0)
	var r4 := absf(pr.riemann_volume(4) - 32.0 * PI / 3.0)
	var r64 := absf(pr.riemann_volume(64) - 32.0 * PI / 3.0)
	_check(r64 < r4 / 200.0 and r4 > 0.1, "Riemann sum converges like 1/n²: error %.4f with 4 disks, %.6f with 64" % [r4, r64])
	pr.free_gpu()


# --- 2/3. Topics in the app -----------------------------------------------------------------------------

func _test_vector_topic_ui() -> void:
	main.load_topic(0)
	await _frames(20)
	await _shot("01_vector_field.png")
	var topic: VectorFieldTopic = main.current_topic
	# Drag the probe with the mouse.
	var camera: Camera3D = main.desktop_camera
	var before := topic.probe_math()
	var start := _screen(topic._probe.global_position)
	_mouse_move(start)
	await _frames(3)
	_mouse_button(MOUSE_BUTTON_LEFT, true, start)
	await _frames(2)
	for i in 10:
		_mouse_move(start + Vector2(-8.0 * (i + 1), -4.0 * (i + 1)))
		await _frames(1)
	_mouse_button(MOUSE_BUTTON_LEFT, false, start + Vector2(-80, -40))
	await _frames(2)
	var after := topic.probe_math()
	_check(after.distance_to(before) > 0.2, "mouse drags the probe %s -> %s" % [Topic.fmt3(before), Topic.fmt3(after)])
	_check("div F = 0.00" in topic._probe_label.text and "curl F = (0.00, 0.00, 2.00)" in topic._probe_label.text,
			"probe label shows div F = 0, curl F = (0, 0, 2) for the rotation")
	# Arrow keys nudge the probe.
	before = topic.probe_math()
	Input.action_press("nudge_right")
	await _wait(0.3)
	Input.action_release("nudge_right")
	await _frames(2)
	_check(topic.probe_math().x > before.x + 0.1, "arrow key moves the probe along x")
	# Typing a function in the HUD box.
	main.hud.focus_function()
	main.hud._function_edit.clear()
	var cam_before := camera.global_position
	await _type("(x, y, z q)")
	_check(main.hud._function_status.text.begins_with("✗") and camera.global_position.distance_to(cam_before) < 1e-3,
			"bad input reported (%s) and typing did not move the camera" % main.hud._function_status.text)
	main.hud.focus_function()
	main.hud._function_edit.clear()
	await _type("(x, y, z)")
	await _frames(5)
	var dc := topic.engine.div_curl(Vector3(0.3, -0.2, 0.5))
	_check(main.hud._function_status.text.begins_with("✓") and absf(dc[0] - 3.0) < 1e-4, "typed (x, y, z) plotted: div F = %.4f" % dc[0])
	# Toggles: field lines from the rake, dye.
	main._on_control("lines", true)
	main._on_control("dye", true)
	main._on_control("preset", 6)  # helix
	await _wait(1.0)
	await _shot("01b_vector_field_lines_dye.png")
	_check(topic._lines.visible and topic.engine.emitter_radius > 0.0, "field lines and dye injection on")
	main._on_control("lines", false)
	main._on_control("dye", false)
	main._on_control("filter", 1)
	await _frames(5)
	await _shot("01c_vector_field_slab.png")
	main._on_control("filter", 0)
	# Quality levels change the instance count.
	main.set_quality(3)
	await _frames(10)
	_check(topic._arrows.multimesh.instance_count == 32 ** 3 and topic.engine.particle_count == 65536,
			"Ultra: 32³ = 32768 arrows, 65536 particles")
	await _shot("01d_vector_field_ultra.png")
	main.set_quality(2)


func _test_div_curl_topic() -> void:
	await _key(KEY_2)
	await _frames(20)
	_check(main.current_index == 1, "key 2 opens Divergence & Curl")
	var topic: DivCurlTopic = main.current_topic
	topic.set_probe_math(Vector3(0.6, -0.3, 0.4))
	topic.on_control("axis", 0)
	topic.update_integrals()
	var area := PI * DivCurlTopic.PROBE_R ** 2
	_check(absf(topic.stokes.circulation - 2.0 * area) < 1e-3 * 2.0 * area,
			"Stokes, rotation: circulation %.5f = curl·n × area %.5f" % [topic.stokes.circulation, 2.0 * area])
	var a0 := topic.wheel_angle
	await _wait(0.5)
	_check(absf(topic.stokes.omega - 1.0) < 1e-3 and absf(topic.wheel_angle - a0) > 0.3,
			"paddle wheel spins at ω = ½ curl·axis = %.3f rad/s" % topic.stokes.omega)
	topic.on_control("axis", 1)
	await _frames(3)
	topic.update_integrals()
	_check(absf(topic.stokes.omega) < 1e-4, "wheel on the x axis does not spin in a z-rotation (ω = %s)" % _sci(topic.stokes.omega))
	main._on_control("preset", 1)  # source
	await _frames(5)
	topic.update_integrals()
	var vol := 4.0 / 3.0 * PI * DivCurlTopic.PROBE_R ** 3
	_check(absf(topic.gauss.flux - 3.0 * vol) < 0.01 * 3.0 * vol and absf(topic.gauss.div - 3.0) < 1e-4,
			"Gauss, source: flux %.5f = div F × volume %.5f" % [topic.gauss.flux, 3.0 * vol])
	await _wait(0.4)
	await _shot("02_div_curl_source.png")
	main._on_control("preset", 4)  # shear: straight lines, nonzero curl
	main._on_control("view", 1)
	main._on_control("slice_mode", 1)
	main._on_control("orientation", 0)
	await _wait(0.4)
	_check(absf(topic.engine.curl(Vector3(0.2, 0.3, 0.1)).z + 1.0) < 1e-4, "shear (y, 0, 0): curl F = (0, 0, −1)")
	await _shot("02b_div_curl_shear.png")
	var pos_before := topic.slice_pos
	for i in 4:
		_mouse_button(MOUSE_BUTTON_WHEEL_UP, true, Vector2(400, 400))
		_mouse_button(MOUSE_BUTTON_WHEEL_UP, false, Vector2(400, 400))
		await _frames(1)
	_check(absf(topic.slice_pos - pos_before - 0.4) < 1e-3, "mouse wheel moves the slice (%.2f -> %.2f)" % [pos_before, topic.slice_pos])
	main._on_control("preset", 10)  # breathing vortex (t)
	main._on_control("view", 0)
	await _wait(0.6)
	var t := topic.engine.t
	var expected := 2.0 * sin(t)
	_check(absf(topic.engine.divergence(Vector3(0.5, 0.5, 0.0)) - expected) < 1e-3, "time-dependent field: div F = 2 sin t = %.3f" % expected)
	await _shot("02c_div_curl_breathing.png")


func _test_gradient_topic() -> void:
	main.load_topic(2)
	await _frames(20)
	var topic: GradientTopic = main.current_topic
	topic.set_probe_xy(Vector2(1.0, 0.5))
	await _frames(2)
	var g: Vector2 = topic.get_debug_state().grad
	_check((g - Vector2(2.0, -1.0)).length() < 1e-4, "saddle x² − y²: ∇f(1, 0.5) = %s (2, −1)" % g)
	topic.direction = atan2(-1.0, 2.0)
	_check(absf(topic.directional_derivative() - sqrt(5.0)) < 1e-4, "D_u f along ∇f = |∇f| = √5 (%.5f)" % topic.directional_derivative())
	topic.direction = atan2(2.0, 1.0)
	_check(absf(topic.directional_derivative()) < 1e-4, "D_u f along a level curve = 0 (%s)" % _sci(topic.directional_derivative()))
	# The probe follows the surface while dragged by the mouse on the xy-plane.
	var start := _screen(topic._probe.global_position)
	_mouse_move(start)
	await _frames(3)
	_mouse_button(MOUSE_BUTTON_LEFT, true, start)
	await _frames(2)
	for i in 8:
		_mouse_move(start + Vector2(-10.0 * (i + 1), 6.0 * (i + 1)))
		await _frames(1)
	_mouse_button(MOUSE_BUTTON_LEFT, false, start + Vector2(-80, 48))
	await _frames(2)
	var xy: Vector2 = topic.probe_xy()
	var on_surface := MeshUtil.to_math(topic._probe.position).z
	_check(xy.distance_to(Vector2(1.0, 0.5)) > 0.2 and absf(on_surface - topic.display_height(xy)) < 1e-4,
			"mouse drag moves the probe over the surface to %s (stays on it)" % xy)
	main._on_control("preset", 2)  # hill: ascent ends at the summit
	main._on_control("path", true)
	topic.set_probe_xy(Vector2(1.2, -0.9))
	await _frames(3)
	var path := topic.ascent_path()
	var end := Vector2(path[path.size() - 1].x, path[path.size() - 1].y)
	_check(end.length() < 0.05, "steepest ascent from (1.2, −0.9) reaches the summit (ends at %s)" % end)
	topic.direction = 0.6
	await _wait(0.3)
	await _shot("03_gradient_hill.png")
	main._on_control("preset", 0)
	main._on_control("path", false)
	topic.set_probe_xy(Vector2(0.8, 0.5))
	await _wait(0.3)
	await _shot("03b_gradient_saddle.png")
	main._on_control("preset", 8)  # ripple (t)
	await _wait(0.5)
	await _shot("03c_gradient_ripple.png")


func _test_parametric_topic() -> void:
	main.load_topic(3)
	await _frames(20)
	var topic: ParametricTopic = main.current_topic
	await _shot("04_parametric_sphere.png")
	main._on_control("preset", 1)  # torus
	await _wait(0.4)
	await _shot("04b_parametric_torus.png")
	main._on_control("preset", 3)  # Möbius
	await _wait(0.4)
	await _shot("04c_parametric_mobius.png")
	main._on_control("preset", 7)  # Dini
	await _frames(5)
	main._on_control("u", 0.4)
	main._on_control("v", 0.5)
	var fr: Dictionary = topic.probe_frame()
	var expect := -1.0 / (1.0 + 0.04)
	_check(absf(fr.K - expect) < 0.01, "Dini's surface: K = %.4f (constant −1/(1 + (a/5)²) = %.4f)" % [fr.K, expect])
	main._on_control("preset", 4)  # helicoid: minimal surface
	await _frames(3)
	fr = topic.probe_frame()
	_check(absf(fr.H) < 1e-3 and fr.K < 0.0, "helicoid is minimal: H = %s, K = %.3f < 0" % [_sci(fr.H), fr.K])
	await _wait(0.3)
	await _shot("04d_parametric_helicoid.png")
	main.submit_function("(u, v, sin(u) cos(v)), u = -2..2, v = -2..2")
	await _frames(5)
	_check(main.hud._function_status.text.begins_with("✓") and is_equal_approx(topic.engine.u_range.x, -2.0),
			"typed parametric surface with ranges")
	main.submit_function("(u, v), u = 0..1")
	_check(main.hud._function_status.text.begins_with("✗"), "missing component reported: " + main.hud._function_status.text)
	main._on_control("preset", 6)  # Klein bottle
	main._on_control("color", 1)
	await _wait(0.4)
	await _shot("04e_parametric_klein.png")


func _test_revolution_topic() -> void:
	main.load_topic(4)
	await _wait(0.5)
	var topic: RevolutionTopic = main.current_topic
	await _shot("05_revolution_sweep.png")
	await _wait(RevolutionTopic.SWEEP_SECONDS)
	_check(is_equal_approx(topic.sweep, TAU), "sweep animation reaches 360°")
	await _shot("05b_revolution_paraboloid.png")
	main._on_control("preset", 3)  # washer
	main._on_control("disks", true)
	main._on_control("count", 12.0)
	main._on_control("slice", 0.25)
	await _wait(0.2)
	var st: Dictionary = topic.get_debug_state()
	_check(absf(st.volume - 8.0 * PI / 3.0) < 1e-3 and st.disks == 12, "washer volume 8π/3 = %.4f; 12 washers drawn" % st.volume)
	_check(absf(st.area - PI * (1.0 - 0.25)) < 1e-4, "cross-section at x = 1: A = π(1 − ¼) = %.4f" % st.area)
	main._on_control("solid", false)
	await _wait(0.2)
	await _shot("05c_revolution_washers.png")
	main._on_control("solid", true)
	main._on_control("disks", false)
	main._on_control("preset", 4)  # torus
	await _wait(RevolutionTopic.SWEEP_SECONDS * 0.6)
	await _shot("05d_revolution_torus_sweep.png")
	var before: float = topic.slice_x
	await _key(KEY_RIGHT)
	Input.action_press("nudge_right")
	await _wait(0.3)
	Input.action_release("nudge_right")
	_check(topic.slice_x > before, "arrow key moves the cross-section (%.2f -> %.2f)" % [before, topic.slice_x])


func _test_backend_and_panels() -> void:
	main.load_topic(0)
	await _frames(10)
	main.set_quality(0)
	await _key(KEY_G)
	await _frames(10)
	_check(main.backend == FieldEngine.Backend.CPU and main.current_topic.engine.get_output("field") is ImageTexture,
			"G switches to the CPU baseline (textures now uploaded from the CPU)")
	var s: Dictionary = main.stats.live()
	_check(s.update_ms > 0.0, "CPU field update time is measured (%.2f ms)" % s.update_ms)
	await _shot("06_cpu_baseline.png")
	await _key(KEY_G)
	await _frames(10)
	_check(main.current_topic.engine.get_output("field") is Texture2DRD, "G again: back to GPU textures (Texture2DRD)")
	main.set_quality(2)
	# VR layout preview: 3D panels on, click a panel button with the mouse.
	await _key(KEY_P)
	await _frames(5)
	_check(main.topic_panel.visible and main.session_panel.visible, "P shows the VR panels")
	var cam: FreeFlyCamera = main.desktop_camera
	var target: Vector3 = main.topic_panel.widget_position("preset", "next")
	cam.reset_view(target + main.topic_panel.global_basis.z * 0.9 + Vector3(0.2, -0.2, 0.0), target)
	await _frames(3)
	var preset_before: int = main.current_topic.preset_index()
	await _click(_screen(target))
	await _frames(3)
	_check(main.current_topic.preset_index() == preset_before + 1, "clicking ▶ on the 3D panel picks the next preset (%d -> %d)" % [preset_before, main.current_topic.preset_index()])
	await _shot("07_vr_panel.png")
	# Keypad: open it from the session panel and type with its keys.
	main.open_editor()
	await _frames(3)
	_check(main.keypad.visible, "keypad opens in the VR layout")
	main.keypad._on_key("C")
	for k in ["(", "-", "y", ",", "x", ",", "z", ")"]:
		main.keypad._on_key(k)
	main.keypad.submitted.emit(main.keypad.text)
	await _frames(3)
	_check(main.current_topic.engine.text == "(-y,x,z)", "keypad-typed field plotted: " + main.current_topic.engine.text)
	var kp: Vector3 = main.keypad.global_position
	cam.reset_view(kp + main.keypad.global_basis.z * 0.9 + Vector3(0, -0.15, 0), kp + Vector3(0, -0.15, 0))
	await _frames(3)
	await _shot("07b_keypad.png")
	main.keypad.visible = false
	# Whole VR layout from the player's position.
	cam.reset_view(main.XR_START + Vector3(0, 1.6, 0.25), main.PLOT_CENTER + Vector3(0, 0.15, 0))
	cam.fov = 95.0
	await _frames(5)
	await _shot("07c_vr_layout.png")
	cam.fov = 70.0
	await _key(KEY_P)
	main.reset_view()


func _test_benchmark_quick() -> void:
	# A short GPU-vs-CPU measurement of the vector field at Low and Medium.
	main.load_topic(0)
	await _frames(10)
	var rows := []
	for backend in [FieldEngine.Backend.GPU, FieldEngine.Backend.CPU]:
		for level in [0, 1]:
			var row: Dictionary = await main.benchmark._measure(0, backend, level, 0.4, 1.0)
			rows.append(row)
	for e: FieldEngine in main.current_engines():
		e.force_every_frame = false
	main.set_backend(FieldEngine.Backend.GPU)
	main.set_quality(2)
	_check(rows[2].update_ms > rows[0].compute_ms, "CPU update (%.2f ms) costs more than the GPU compute (%.3f ms) at Low" % [rows[2].update_ms, rows[0].compute_ms])
	_check(rows[0].compute_ms > 0.0, "GPU compute time measured with timestamps (%.4f ms)" % rows[0].compute_ms)
