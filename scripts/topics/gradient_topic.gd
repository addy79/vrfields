class_name GradientTopic
extends Topic
## Surface z = f(x, y) computed and displaced on the GPU, with level curves and
## a grid of gradient arrows ∇f on the floor of the box. A probe on the surface
## shows the tangent plane, ∇f, a chosen direction u and the directional
## derivative D_u f = ∇f · u, and can trace the path of steepest ascent.

const EXTENT := 2.0
const RESOLUTION := [48, 96, 160, 256]
const ARROW_GRID := [9, 13, 17, 21]
const BASE_Z := -1.9
const COLOR_MODES: PackedStringArray = ["Height", "|∇f|"]
const PRESETS: Array[Dictionary] = [
	{"name": "Saddle", "text": "x^2 - y^2",
		"note": "∇f = (2x, −2y). At the origin ∇f = 0, yet it is neither a max nor a min.\nArrows point uphill and cross the level curves at right angles."},
	{"name": "Bowl", "text": "x^2 + y^2",
		"note": "∇f = (2x, 2y) points straight away from the minimum; |∇f| grows with distance.\nLevel curves are circles."},
	{"name": "Hill", "text": "2exp(-(x^2 + y^2))",
		"note": "The gradient points to the summit, and vanishes there (∇f = 0 at the maximum)."},
	{"name": "Egg crate", "text": "sin(x) cos(y)",
		"note": "Maxima, minima and saddles side by side: ∇f = 0 at all of them.\nTrace steepest-ascent paths from different starts: they end at different peaks."},
	{"name": "Monkey saddle", "text": "(x^3 - 3x y^2) / 4",
		"note": "A saddle with three valleys: ∇f = 0 at the origin and the second-derivative test fails (D = 0)."},
	{"name": "Two peaks", "text": "exp(-((x - 1)^2 + y^2)) + 0.8exp(-((x + 1)^2 + (y - 1)^2) / 0.5)",
		"note": "Two local maxima. Steepest ascent finds the nearest one, not the highest."},
	{"name": "Plane", "text": "a x + b y",
		"note": "∇f = (a, b) is the same everywhere. D_u f = a cos θ + b sin θ is largest along ∇f\n(value |∇f|), zero along the level lines, and −|∇f| opposite to ∇f."},
	{"name": "Peaks", "text": "(x^2 + 3y^2) exp(1 - x^2 - y^2)",
		"note": "A minimum at the origin, two maxima at (0, ±1) and saddles at (±1, 0)."},
	{"name": "Ripple (t)", "text": "sin(3sqrt(x^2 + y^2) - 2t) / 2",
		"note": "Time-dependent: rings move outwards; ∇f flips direction every half wavelength.\nRecomputed on the GPU every frame."},
]

var engine := ScalarSurfaceEngine.new()
var color_mode := 0
var show_arrows := true
var show_tangent := true
var show_path := false
## Direction for the directional derivative, radians from +x.
var direction := 0.6
var height_gain := 1.0
var z_scale := 1.0
var z_offset := 0.0

var _surface := MeshInstance3D.new()
var _surface_mat := Topic.shader_material("res://shaders/scalar_surface.gdshader")
var _arrows := MultiMeshInstance3D.new()
var _arrow_mat := Topic.shader_material("res://shaders/arrows.gdshader")
var _probe := Grabbable.new("sphere", Vector3(0.08, 0, 0), Color(1, 1, 1))
var _tangent := MeshInstance3D.new()
var _grad_arrow := MeshUtil.make_arrow(Color(1.0, 0.3, 0.85), 0.025)
var _dir_arrow := MeshUtil.make_arrow(Color(0.3, 0.95, 1.0), 0.025)
var _floor_grad := MeshUtil.make_arrow(Color(1.0, 0.3, 0.85), 0.03)
var _drop := MeshInstance3D.new()
var _path := MeshInstance3D.new()
var _probe_label := MeshUtil.label("", 34)
var _probe_xy := Vector2(0.8, 0.5)


func _init() -> void:
	topic_title = "Gradient"


func engines() -> Array[FieldEngine]:
	return [engine]


func presets() -> Array[Dictionary]:
	return PRESETS


func _build() -> void:
	engine.extent = EXTENT
	plot.add_child(Topic.make_box_and_axes(EXTENT))
	var big := AABB(Vector3.ONE * -EXTENT * 1.6, Vector3.ONE * EXTENT * 3.2)
	_surface.material_override = _surface_mat
	_surface.custom_aabb = big
	_surface_mat.set_shader_parameter("extent", EXTENT)
	plot.add_child(_surface)

	_arrows.material_override = _arrow_mat
	_arrows.custom_aabb = big
	_arrow_mat.set_shader_parameter("mode", 1)
	_arrow_mat.set_shader_parameter("extent", EXTENT)
	_arrow_mat.set_shader_parameter("base_z", BASE_Z)
	_arrow_mat.set_shader_parameter("length_scale", 0.85)
	_arrow_mat.set_shader_parameter("thickness", 0.035)
	plot.add_child(_arrows)

	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.material = MeshUtil.flat_material(Color(0.75, 0.9, 1.0, 0.4), true)
	_tangent.mesh = quad
	plot.add_child(_tangent)
	for n: Node3D in [_grad_arrow, _dir_arrow, _floor_grad]:
		plot.add_child(n)
	var drop_mesh := CylinderMesh.new()
	drop_mesh.top_radius = 0.008
	drop_mesh.bottom_radius = 0.008
	drop_mesh.height = 1.0
	drop_mesh.material = MeshUtil.flat_material(Color(1, 1, 1, 0.5), true)
	_drop.mesh = drop_mesh
	plot.add_child(_drop)
	_path.mesh = ImmediateMesh.new()
	plot.add_child(_path)

	_probe.drag_plane = true
	_probe.constrain = func(local: Transform3D) -> Transform3D:
		var m := MeshUtil.to_math(local.origin)
		_probe_xy = Vector2(clampf(m.x, -EXTENT, EXTENT), clampf(m.y, -EXTENT, EXTENT))
		local.origin = MeshUtil.to_godot(Vector3(_probe_xy.x, _probe_xy.y, display_height(_probe_xy)))
		return local
	_probe.moved.connect(_update_probe)
	plot.add_child(_probe)
	_probe_label.pixel_size = 0.0035
	_probe_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	plot.add_child(_probe_label)


func apply_quality() -> void:
	engine.resolution = RESOLUTION[quality]
	_surface.mesh = MeshUtil.grid_mesh(engine.resolution)
	_surface_mat.set_shader_parameter("resolution", engine.resolution)
	_arrow_mat.set_shader_parameter("surface_res", engine.resolution)
	var g: int = ARROW_GRID[quality]
	_arrows.multimesh = MeshUtil.identity_multimesh(MeshUtil.arrow_mesh(), g * g)
	_arrow_mat.set_shader_parameter("grid_n", g)
	engine.dirty = true


func _apply_preset(index: int) -> void:
	set_function(PRESETS[index].text)
	function_text_changed.emit(PRESETS[index].text)


func set_function(text: String) -> String:
	var error := engine.set_function(text)
	if error.is_empty():
		_fit_height()
	return error


## Display height (math units) of the surface above (x, y).
func display_height(xy: Vector2) -> float:
	return (engine.f(xy.x, xy.y) - z_offset) * z_scale


## Chooses z_scale/z_offset so the surface fits in the box (CPU sample, 33 × 33).
func _fit_height() -> void:
	var lo := INF
	var hi := -INF
	for j in 33:
		for i in 33:
			var v := engine.f(lerpf(-EXTENT, EXTENT, i / 32.0), lerpf(-EXTENT, EXTENT, j / 32.0))
			lo = minf(lo, v)
			hi = maxf(hi, v)
	z_offset = (lo + hi) * 0.5
	z_scale = minf(1.0, 1.5 * EXTENT / maxf(hi - lo, 1e-6)) * height_gain
	_surface_mat.set_shader_parameter("z_scale", z_scale)
	_surface_mat.set_shader_parameter("z_offset", z_offset)
	_update_probe()


func get_function_spec() -> Dictionary:
	return {"label": "f(x, y) =", "text": engine.text, "variables": PackedStringArray(ScalarSurfaceEngine.VARIABLES),
			"help": "e.g. x^2 - y^2 or sin(x) cos(y). Use t for time, a and b for the sliders."}


func get_controls() -> Array:
	return [
		ControlSpec.choice("preset", "Function", preset_names(), _preset_index),
		ControlSpec.slider("a", "a", -3.0, 3.0, 0.05, engine.param_a),
		ControlSpec.slider("b", "b", -3.0, 3.0, 0.05, engine.param_b),
		ControlSpec.slider("direction", "Direction θ°", 0.0, 360.0, 5.0, rad_to_deg(direction), "%.0f°"),
		ControlSpec.toggle("arrows", "∇f arrows on the floor", show_arrows),
		ControlSpec.toggle("tangent", "Tangent plane", show_tangent),
		ControlSpec.toggle("path", "Steepest-ascent path", show_path),
		ControlSpec.choice("color", "Colour", COLOR_MODES, color_mode),
		ControlSpec.slider("height", "Height ×", 0.25, 2.0, 0.05, height_gain),
	]


func on_control(id: String, value: Variant) -> void:
	match id:
		"preset":
			select_preset(value)
		"a":
			set_params(value, engine.param_b)
			_fit_height()
		"b":
			set_params(engine.param_a, value)
			_fit_height()
		"direction":
			direction = deg_to_rad(value)
			_update_probe()
		"arrows":
			show_arrows = value
		"tangent":
			show_tangent = value
			_update_probe()
		"path":
			show_path = value
			_update_probe()
		"color":
			color_mode = value
		"height":
			height_gain = value
			_fit_height()


func set_probe_xy(xy: Vector2) -> void:
	_probe.set_local_constrained(Transform3D(Basis.IDENTITY, MeshUtil.to_godot(Vector3(xy.x, xy.y, 0.0))))


func probe_xy() -> Vector2:
	return _probe_xy


func handle_nudge(axis: Vector2, delta: float) -> void:
	set_probe_xy(_probe_xy + axis * 1.2 * delta)


func handle_scroll(steps: float) -> void:
	direction = fposmod(direction + steps * deg_to_rad(10.0), TAU)
	control_value_changed.emit("direction", snappedf(rad_to_deg(direction), 5.0))
	_update_probe()


func handle_action() -> void:
	show_path = not show_path
	control_value_changed.emit("path", show_path)
	_update_probe()


func get_hint() -> String:
	return "Drag the white probe over the surface (or arrow keys). Wheel turns the direction u.\n" \
			+ "Magenta = ∇f, cyan = u. Space: steepest-ascent path."


func directional_derivative() -> float:
	return engine.gradient(_probe_xy.x, _probe_xy.y).dot(Vector2(cos(direction), sin(direction)))


func _update_probe() -> void:
	if engine.expr == null:
		return
	var xy := _probe_xy
	var h := display_height(xy)
	var p := Vector3(xy.x, xy.y, h)
	_probe.position = MeshUtil.to_godot(p)
	var g := engine.gradient(xy.x, xy.y)
	var n := Vector3(-g.x * z_scale, -g.y * z_scale, 1.0).normalized()
	_tangent.visible = show_tangent
	var n_g := MeshUtil.to_godot(n)
	_tangent.transform = Transform3D(Basis.looking_at(-n_g, Vector3.FORWARD if absf(n_g.y) > 0.9 else Vector3.UP), _probe.position)
	# Arrows along the surface: the step (u, D_u f) in display units.
	var u := Vector2(cos(direction), sin(direction))
	var du := g.dot(u)
	MeshUtil.set_arrow(_dir_arrow, MeshUtil.to_godot(Vector3(u.x, u.y, du * z_scale).normalized() * 0.8))
	_dir_arrow.position = _probe.position
	var gl := g.length()
	if gl > 1e-6:
		var gu := g / gl
		MeshUtil.set_arrow(_grad_arrow, MeshUtil.to_godot(Vector3(gu.x, gu.y, gl * z_scale).normalized() * 0.8))
	else:
		MeshUtil.set_arrow(_grad_arrow, Vector3.ZERO)
	_grad_arrow.position = _probe.position
	var top := maxf(engine.max_gradient, 1e-6)
	MeshUtil.set_arrow(_floor_grad, MeshUtil.to_godot(Vector3(g.x, g.y, 0.0)) * (0.9 / top))
	_floor_grad.position = MeshUtil.to_godot(Vector3(xy.x, xy.y, BASE_Z + 0.02))
	var drop_len := absf(h - BASE_Z)
	_drop.scale = Vector3(1.0, drop_len, 1.0)
	_drop.position = MeshUtil.to_godot(Vector3(xy.x, xy.y, (h + BASE_Z) * 0.5))
	_probe_label.position = _probe.position + Vector3(0.2, 0.3, 0.0)
	_probe_label.text = "f = %.3f\n∇f = (%.2f, %.2f)   |∇f| = %.2f\nD_u f = ∇f·u = %.3f  (θ = %.0f°)" % [
			engine.f(xy.x, xy.y), g.x, g.y, gl, du, rad_to_deg(direction)]
	_draw_path()


## Steepest ascent from the probe: dp/ds = ∇f / |∇f| (midpoint rule, step 0.03).
func ascent_path() -> PackedVector3Array:
	var pts := PackedVector3Array()
	var p := _probe_xy
	for i in 400:
		pts.append(Vector3(p.x, p.y, display_height(p) + 0.03))
		var g := engine.gradient(p.x, p.y)
		if g.length() < 1e-3:
			break
		var mid := p + g.normalized() * 0.015
		var gm := engine.gradient(mid.x, mid.y)
		if gm.length() < 1e-3:
			break
		p += gm.normalized() * 0.03
		if absf(p.x) > EXTENT or absf(p.y) > EXTENT:
			break
	return pts


func _draw_path() -> void:
	var mesh := _path.mesh as ImmediateMesh
	mesh.clear_surfaces()
	_path.visible = show_path
	if not show_path:
		return
	var pts := ascent_path()
	if pts.size() < 2:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, MeshUtil.flat_material(Color(1.0, 1.0, 1.0), true))
	for q in pts:
		mesh.surface_add_vertex(MeshUtil.to_godot(q))
	mesh.surface_end()


func _update_topic(_delta: float) -> void:
	_arrows.visible = show_arrows
	_surface_mat.set_shader_parameter("color_mode", color_mode)
	if engine.is_time_dependent():
		_update_probe()


func _bind_outputs() -> void:
	var surface := engine.get_output("surface")
	var stats := engine.get_output("stats")
	Topic.bind_texture(_surface_mat, "surface_tex", surface)
	Topic.bind_texture(_surface_mat, "stats_tex", stats)
	Topic.bind_texture(_arrow_mat, "data_tex", surface)
	Topic.bind_texture(_arrow_mat, "stats_tex", stats)


func _make_readout() -> String:
	return "f(x, y) = %s\nHeight shown ×%.2f.  Level curves every 1/14 of the range.\nmax |∇f| on the grid = %.2f\n\n%s" % [
			engine.text, z_scale, engine.max_gradient, explanation()]


func workload() -> Dictionary:
	var g: int = ARROW_GRID[quality]
	return {"surface points": engine.resolution ** 2, "gradient arrows": g * g}


func get_debug_state() -> Dictionary:
	var g := engine.gradient(_probe_xy.x, _probe_xy.y)
	return {"probe": _probe_xy, "grad": g, "du": directional_derivative(), "direction": direction,
			"path_points": ascent_path().size() if show_path else 0, "resolution": engine.resolution,
			"z_scale": z_scale}
