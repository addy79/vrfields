class_name RevolutionTopic
extends Topic
## Solids of revolution about the x-axis. The compute shader samples the
## profile curves (outer f, inner g) into a texture; the vertex shader sweeps
## them around the axis (animated 0 → 360°). A movable slice shows the
## cross-section A(x) = π|f² − g²|, and n disks/washers show the Riemann sum
## converging to V = ∫ A(x) dx (Simpson's rule, 2000 intervals).
## Typed input: "f(x), g(x), x = 0..4" (g and the range optional).

const EXTENT := 2.0
const RESOLUTION := [64, 128, 256, 512]
const SWEEP_SECONDS := 4.0
const PRESETS: Array[Dictionary] = [
	{"name": "Paraboloid", "text": "sqrt(x), x = 0..4",
		"note": "Disk method: A(x) = π(√x)² = πx, so V = ∫₀⁴ πx dx = 8π ≈ 25.133."},
	{"name": "Sphere", "text": "sqrt(4 - (x - 2)^2), x = 0..4",
		"note": "A half-disk of radius 2 swept around: V = 4/3 π 2³ = 32π/3 ≈ 33.510."},
	{"name": "Cone", "text": "x / 2, x = 0..4",
		"note": "Radius grows linearly: V = π∫₀⁴ x²/4 dx = 16π/3 ≈ 16.755 (⅓ of the cylinder)."},
	{"name": "Washer: paraboloid minus cone", "text": "sqrt(x), x / 2, x = 0..4",
		"note": "Washer method: A(x) = π(f² − g²) = π(x − x²/4), V = 8π/3 ≈ 8.378."},
	{"name": "Torus", "text": "1.5 + sqrt(0.25 - (x - 2)^2), 1.5 - sqrt(0.25 - (x - 2)^2), x = 1.5..2.5",
		"note": "A circle of radius r = 0.5 at distance R = 1.5 from the axis: V = 2π²Rr² ≈ 7.402\n(Pappus: area πr² times the distance 2πR its centre travels)."},
	{"name": "Vase", "text": "1 + sin(2x) / 2 + x / 4, x = 0..4",
		"note": "Any profile works: the disks follow the bulges. Watch the Riemann sum converge."},
	{"name": "Gabriel's horn", "text": "1 / x, x = 1..8",
		"note": "V = π∫₁⁸ dx/x² = 7π/8 ≈ 2.749. Even to x = ∞ the volume is finite (π),\nwhile the surface area grows without bound."},
	{"name": "Pulsing (t)", "text": "1 + a sin(2x - 2t) / 2, x = 0..4",
		"note": "Time-dependent profile: the solid ripples and V(t) changes; recomputed every frame."},
]

var engine := ProfileEngine.new()
var show_solid := true
var show_disks := false
var disk_count := 8
var animate_sweep := true
var sweep := TAU
var slice_x := 2.0
var fit := 1.0

var _solid_root := Node3D.new()
var _solid := MeshInstance3D.new()
var _solid_mat := Topic.shader_material("res://shaders/revolution.gdshader")
var _disks := MultiMeshInstance3D.new()
var _disk_mat := Topic.shader_material("res://shaders/washers.gdshader")
var _slice := MultiMeshInstance3D.new()
var _slice_mat := Topic.shader_material("res://shaders/washers.gdshader")
var _handle := Grabbable.new("sphere", Vector3(0.12, 0, 0), Color(1.0, 0.5, 0.25))
var _axis := MeshUtil.make_arrow(Color(1.0, 0.45, 0.45), 0.02)
var _label := MeshUtil.label("", 34)
var _sweep_clock := 0.0


func _init() -> void:
	topic_title = "Solids of Revolution"


func engines() -> Array[FieldEngine]:
	return [engine]


func presets() -> Array[Dictionary]:
	return PRESETS


func _build() -> void:
	plot.add_child(_solid_root)
	var big := AABB(Vector3(-20, -20, -20), Vector3(40, 40, 40))
	_solid.mesh = MeshUtil.revolution_mesh(160, 64)
	_solid.material_override = _solid_mat
	_solid.custom_aabb = big
	_solid_root.add_child(_solid)
	var washer := MeshUtil.washer_mesh(48)
	_disks.multimesh = MeshUtil.identity_multimesh(washer, disk_count)
	_disks.material_override = _disk_mat
	_disks.custom_aabb = big
	_solid_root.add_child(_disks)
	_slice.multimesh = MeshUtil.identity_multimesh(washer, 1)
	_slice.material_override = _slice_mat
	_slice.custom_aabb = big
	_slice_mat.set_shader_parameter("slice_mode", true)
	_slice_mat.set_shader_parameter("color", Color(1.0, 0.85, 0.25))
	_solid_root.add_child(_slice)
	_solid_root.add_child(_axis)
	_handle.drag_plane = true
	_handle.drag_plane_normal = Vector3(0, 0, 1)
	_handle.constrain = func(local: Transform3D) -> Transform3D:
		var m := MeshUtil.to_math(local.origin)
		slice_x = clampf(m.x, engine.x_range.x, engine.x_range.y)
		local.origin = _handle_position()
		return local
	_handle.moved.connect(func() -> void: control_value_changed.emit("slice", slice_fraction()))
	_solid_root.add_child(_handle)
	_label.pixel_size = 0.0035
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	plot.add_child(_label)


func apply_quality() -> void:
	engine.resolution = RESOLUTION[quality]
	for m: ShaderMaterial in [_solid_mat, _disk_mat, _slice_mat]:
		m.set_shader_parameter("resolution", engine.resolution)
	engine.dirty = true


func _apply_preset(index: int) -> void:
	set_function(PRESETS[index].text)
	function_text_changed.emit(PRESETS[index].text)


## Parses "f, g, x = a..b" into {"outer", "inner", "range", "error"}.
static func parse_input(text: String) -> Dictionary:
	var pieces := ParametricTopic._top_level_split(text)
	var funcs := PackedStringArray()
	var range := Vector2(0.0, 4.0)
	for piece in pieces:
		var eq := piece.find("=")
		if eq > 0 and piece.substr(0, eq).strip_edges() == "x":
			var bounds := piece.substr(eq + 1).split("..")
			if bounds.size() != 2:
				return {"error": "Write the range like x = 0..4"}
			var lo := MathExpr.compile(bounds[0], PackedStringArray())
			var hi := MathExpr.compile(bounds[1], PackedStringArray())
			if not lo.is_valid() or not hi.is_valid():
				return {"error": "Range: " + (lo.error if not lo.is_valid() else hi.error)}
			range = Vector2(lo.evaluate([]), hi.evaluate([]))
		else:
			funcs.append(piece)
	if funcs.is_empty() or funcs.size() > 2:
		return {"error": "Give f(x), or f(x), g(x) for washers"}
	return {"error": "", "outer": funcs[0], "inner": funcs[1] if funcs.size() == 2 else "0", "range": range}


func set_function(text: String) -> String:
	var parsed := parse_input(text)
	if not parsed.error.is_empty():
		return parsed.error
	var r: Vector2 = parsed.range
	var error := engine.set_profile(parsed.outer, parsed.inner, r.x, r.y)
	if error.is_empty():
		engine.outer_text = text.strip_edges()
		slice_x = clampf(slice_x, r.x, r.y) if slice_x > r.x and slice_x < r.y else (r.x + r.y) * 0.5
		_sweep_clock = 0.0
		_fit()
	return error


func _fit() -> void:
	var r := engine.x_range
	var top := 1e-6
	for i in 201:
		var x := lerpf(r.x, r.y, i / 200.0)
		top = maxf(top, maxf(engine.outer_radius(x), engine.inner_radius(x)))
	fit = minf(1.3, minf(2.0 * EXTENT * 0.92 / (r.y - r.x), EXTENT * 0.92 / top))
	_solid_root.scale = Vector3.ONE * fit
	_solid_root.position = MeshUtil.to_godot(Vector3(-(r.x + r.y) * 0.5 * fit, 0.0, 0.0))
	for m: ShaderMaterial in [_disk_mat, _slice_mat]:
		m.set_shader_parameter("x_min", r.x)
		m.set_shader_parameter("x_max", r.y)
	_axis.position = MeshUtil.to_godot(Vector3(r.x - 0.4, 0.0, 0.0))
	MeshUtil.set_arrow(_axis, MeshUtil.to_godot(Vector3(r.y - r.x + 0.9, 0.0, 0.0)))
	_handle.position = _handle_position()
	_max_radius = top


var _max_radius := 1.0
## Cached integrals: thousands of evaluations, so not every readout refresh.
var _volumes := {}
var _volume_age := 0.0


func _handle_position() -> Vector3:
	return MeshUtil.to_godot(Vector3(slice_x, 0.0, -(_max_radius + 0.35)))


func slice_fraction() -> float:
	var r := engine.x_range
	return (slice_x - r.x) / maxf(r.y - r.x, 1e-6)


func set_slice_fraction(f: float) -> void:
	var r := engine.x_range
	slice_x = lerpf(r.x, r.y, clampf(f, 0.0, 1.0))
	_handle.position = _handle_position()


func get_function_spec() -> Dictionary:
	return {"label": "radius f(x) =", "text": engine.outer_text, "variables": PackedStringArray(ProfileEngine.VARIABLES),
			"help": "f(x)  or  f(x), g(x)  for washers, then the range: sqrt(x), x/2, x = 0..4"}


func get_controls() -> Array:
	return [
		ControlSpec.choice("preset", "Solid", preset_names(), _preset_index),
		ControlSpec.slider("a", "a", -3.0, 3.0, 0.05, engine.param_a),
		ControlSpec.toggle("sweep_anim", "Animate the sweep", animate_sweep),
		ControlSpec.slider("sweep", "Sweep angle", 0.0, 360.0, 5.0, rad_to_deg(sweep), "%.0f°"),
		ControlSpec.toggle("solid", "Solid", show_solid),
		ControlSpec.toggle("disks", "Disks / washers (Riemann sum)", show_disks),
		ControlSpec.slider("count", "Number n", 1.0, 64.0, 1.0, disk_count, "%.0f"),
		ControlSpec.slider("slice", "Cross-section at", 0.0, 1.0, 0.01, slice_fraction()),
	]


func on_control(id: String, value: Variant) -> void:
	match id:
		"preset":
			select_preset(value)
		"a":
			set_params(value, engine.param_b)
			_fit()
		"sweep_anim":
			animate_sweep = value
			if value:
				_sweep_clock = 0.0
		"sweep":
			animate_sweep = false
			control_value_changed.emit("sweep_anim", false)
			sweep = deg_to_rad(value)
		"solid":
			show_solid = value
		"disks":
			show_disks = value
		"count":
			set_disk_count(int(value))
		"slice":
			set_slice_fraction(value)


func set_disk_count(n: int) -> void:
	disk_count = clampi(n, 1, 64)
	_disks.multimesh = MeshUtil.identity_multimesh(_disks.multimesh.mesh, disk_count)
	_disk_mat.set_shader_parameter("count", disk_count)


func handle_nudge(axis: Vector2, delta: float) -> void:
	set_slice_fraction(slice_fraction() + axis.x * 0.3 * delta)
	control_value_changed.emit("slice", snappedf(slice_fraction(), 0.01))


func handle_scroll(steps: float) -> void:
	set_disk_count(disk_count + int(signf(steps)))
	control_value_changed.emit("count", disk_count)


func handle_action() -> void:
	show_disks = not show_disks
	control_value_changed.emit("disks", show_disks)


func get_hint() -> String:
	return "Drag the orange handle (or ←/→) to move the cross-section. Wheel: number of disks.\n" \
			+ "Space: show the disks/washers whose total volume approximates the integral."


func _update_topic(delta: float) -> void:
	_volume_age += delta
	if animate_sweep:
		_sweep_clock += delta
		sweep = clampf(_sweep_clock / SWEEP_SECONDS, 0.0, 1.0) * TAU
	_solid_mat.set_shader_parameter("sweep", maxf(sweep, 0.001))
	_solid_mat.set_shader_parameter("show_region", sweep < TAU - 0.01)
	_solid.visible = show_solid
	_disks.visible = show_disks
	_slice_mat.set_shader_parameter("slice_u", slice_fraction())
	_slice_mat.set_shader_parameter("slice_thickness", 0.04 / fit)
	_label.position = plot.transform.affine_inverse() * _handle.global_position + Vector3(0.2, -0.35, 0.0)
	_label.text = "x = %.2f\nf = %.3f   g = %.3f\nA(x) = π|f² − g²| = %.3f" % [
			slice_x, engine.outer_radius(slice_x), engine.inner_radius(slice_x), engine.area(slice_x)]


func _bind_outputs() -> void:
	var profile := engine.get_output("profile")
	for m: ShaderMaterial in [_solid_mat, _disk_mat, _slice_mat]:
		Topic.bind_texture(m, "profile_tex", profile)


## {"exact", "riemann", "to_slice"}; recomputed when inputs change (or at 2 Hz if t-dependent).
func volumes() -> Dictionary:
	var key := [engine.outer_text, engine.param_a, disk_count, slice_x, engine.x_range]
	var stale: bool = _volumes.get("key") != key or (engine.is_time_dependent() and _volume_age > 0.5)
	if stale:
		_volumes = {"key": key, "exact": engine.volume_to(engine.x_range.y),
				"riemann": engine.riemann_volume(disk_count), "to_slice": engine.volume_to(slice_x)}
		_volume_age = 0.0
	return _volumes


func _make_readout() -> String:
	var v := volumes()
	var exact: float = v.exact
	var riemann: float = v.riemann
	return ("%s   (x from %.2f to %.2f)\n" % [engine.outer_text, engine.x_range.x, engine.x_range.y]
		+ "V = ∫ π|f² − g²| dx = %.4f   (Simpson, 2000 steps)\n" % exact
		+ "%d disks (midpoint Riemann sum) = %.4f   error %.2f%%\n" % [disk_count, riemann, 100.0 * absf(riemann - exact) / maxf(exact, 1e-9)]
		+ "Volume up to the slice: %.4f\n\n%s" % [v.to_slice, explanation()])


func workload() -> Dictionary:
	return {"profile samples": engine.resolution, "surface vertices": 160 * 64 * 2}


func get_debug_state() -> Dictionary:
	var v := volumes()
	return {"volume": v.exact, "riemann": v.riemann,
			"slice_x": slice_x, "area": engine.area(slice_x), "sweep": sweep, "disks": disk_count,
			"range": engine.x_range}
