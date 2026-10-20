class_name DivCurlTopic
extends Topic
## Divergence and curl of F. The compute shader fills an M³ volume with
## (div F, curl F); it is shown by ray-marched volume rendering and by a
## slicing plane you can grab and turn. The probe carries a paddle wheel that
## spins at ω = ½ (curl F)·axis, a small sphere for Gauss's theorem
## (flux out ≈ div F × volume) and a loop for Stokes's theorem
## (circulation ≈ (curl F)·n × area), both integrated numerically.

const EXTENT := 2.0
const VOLUME := [16, 32, 48, 64]
const ARROW_GRID := 8
const VIEWS: PackedStringArray = ["div F cloud", "|curl F| cloud", "No cloud"]
const SLICE_MODES: PackedStringArray = ["div F", "curl F · n", "|curl F|"]
const ORIENTATIONS: PackedStringArray = ["Horizontal (z)", "Vertical (y)", "Vertical (x)"]
const AXES: PackedStringArray = ["z", "x", "y", "Along curl F"]
## Radius (math units) of the Gauss sphere and the Stokes loop.
const PROBE_R := 0.35
const SPHERE_SAMPLES := 400
const LOOP_SAMPLES := 96

var engine := VectorFieldEngine.new()
var view_mode := 0
var show_slice := true
var slice_mode := 0
var orientation := 0
var slice_pos := 0.0
var show_arrows := true
var show_particles := false
var axis_mode := 0
var wheel_angle := 0.0
## Latest probe integrals (for the readout and tests).
var gauss := {}
var stokes := {}
## The surface integrals cost ~1500 evaluations, so they refresh at 10 Hz.
var _integral_timer := 0.0

var _volume := MeshInstance3D.new()
var _volume_mat := Topic.shader_material("res://shaders/volume.gdshader")
var _slice := Grabbable.new("box", Vector3(0.12, 0.12, 0.12), Color(0.95, 0.95, 0.95))
var _slice_quad := MeshInstance3D.new()
var _slice_mat := Topic.shader_material("res://shaders/slice.gdshader")
var _arrows := MultiMeshInstance3D.new()
var _arrow_mat := Topic.shader_material("res://shaders/arrows.gdshader")
var _particles := MultiMeshInstance3D.new()
var _particle_mat := Topic.shader_material("res://shaders/particles.gdshader")
var _probe := Grabbable.new("sphere", Vector3(0.09, 0, 0), Color(1, 1, 1))
var _wheel := Node3D.new()
var _sphere := MeshInstance3D.new()
var _loop := MeshInstance3D.new()
var _probe_label := MeshUtil.label("", 34)


func _init() -> void:
	topic_title = "Divergence & Curl"


func engines() -> Array[FieldEngine]:
	return [engine]


func presets() -> Array[Dictionary]:
	return FieldPresets.LIST


func _build() -> void:
	engine.extent = EXTENT
	engine.volume_enabled = true
	engine.grid_n = ARROW_GRID
	engine.particle_count = 4096
	engine.particles_enabled = false
	plot.add_child(Topic.make_box_and_axes(EXTENT))
	var big := AABB(Vector3.ONE * -EXTENT * 1.6, Vector3.ONE * EXTENT * 3.2)

	var box := BoxMesh.new()
	box.size = Vector3(2, 2, 2)
	_volume.mesh = box
	_volume.scale = Vector3.ONE * EXTENT
	_volume.material_override = _volume_mat
	plot.add_child(_volume)

	_arrows.material_override = _arrow_mat
	_arrows.custom_aabb = big
	_arrows.multimesh = MeshUtil.identity_multimesh(MeshUtil.arrow_mesh(), ARROW_GRID ** 3)
	_arrow_mat.set_shader_parameter("grid_n", ARROW_GRID)
	_arrow_mat.set_shader_parameter("extent", EXTENT)
	_arrow_mat.set_shader_parameter("length_scale", 0.5)
	_arrow_mat.set_shader_parameter("thickness", 0.03)
	plot.add_child(_arrows)

	_particles.material_override = _particle_mat
	_particles.custom_aabb = big
	_particles.multimesh = MeshUtil.identity_multimesh(QuadMesh.new(), engine.particle_count)
	_particle_mat.set_shader_parameter("rows", engine.particle_rows())
	_particle_mat.set_shader_parameter("width", 0.004)
	_particle_mat.set_shader_parameter("streak", 0.025)
	plot.add_child(_particles)

	# Slice: the handle sits at the plane's corner; the plane spans the box.
	var quad := QuadMesh.new()
	quad.size = Vector2(EXTENT * 2.0, EXTENT * 2.0)
	_slice_quad.mesh = quad
	_slice_quad.material_override = _slice_mat
	_slice.add_child(_slice_quad)
	_slice.follow_rotation = true
	_slice.constrain = func(local: Transform3D) -> Transform3D:
		local.origin = local.origin.clamp(Vector3.ONE * -EXTENT, Vector3.ONE * EXTENT)
		return local
	_slice.moved.connect(_on_slice_moved)
	plot.add_child(_slice)

	_probe.follow_rotation = true
	_probe.constrain = func(local: Transform3D) -> Transform3D:
		local.origin = local.origin.clamp(Vector3.ONE * -EXTENT, Vector3.ONE * EXTENT)
		return local
	_probe.position = MeshUtil.to_godot(Vector3(0.9, -0.6, 0.7))
	plot.add_child(_probe)
	_build_wheel()
	_probe.add_child(_wheel)
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = PROBE_R
	sphere_mesh.height = PROBE_R * 2.0
	sphere_mesh.material = MeshUtil.flat_material(Color(0.6, 0.9, 1.0, 0.15), true)
	_sphere.mesh = sphere_mesh
	_probe.add_child(_sphere)
	_loop.mesh = _circle_mesh(PROBE_R, Color(1.0, 0.85, 0.2))
	plot.add_child(_loop)
	_probe_label.pixel_size = 0.0035
	_probe_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	plot.add_child(_probe_label)
	_set_orientation(0)


func _build_wheel() -> void:
	var mat := MeshUtil.flat_material(Color(1.0, 0.85, 0.2))
	var hub := MeshInstance3D.new()
	var hub_mesh := CylinderMesh.new()
	hub_mesh.top_radius = 0.02
	hub_mesh.bottom_radius = 0.02
	hub_mesh.height = 0.5
	hub_mesh.material = MeshUtil.flat_material(Color(0.8, 0.8, 0.85))
	hub.mesh = hub_mesh
	_wheel.add_child(hub)
	for i in 4:
		var blade := MeshInstance3D.new()
		var blade_mesh := BoxMesh.new()
		blade_mesh.size = Vector3(0.28, 0.16, 0.012)
		blade_mesh.material = mat
		blade.mesh = blade_mesh
		var angle := i * PI * 0.5
		blade.transform = Transform3D(Basis(Vector3.UP, angle), Basis(Vector3.UP, angle) * Vector3(0.16, 0.0, 0.0))
		_wheel.add_child(blade)


static func _circle_mesh(r: float, color: Color) -> ImmediateMesh:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, MeshUtil.flat_material(color, true))
	for i in 65:
		var a := TAU * i / 64.0
		mesh.surface_add_vertex(Vector3(cos(a), 0.0, sin(a)) * r)
	mesh.surface_end()
	return mesh


func apply_quality() -> void:
	engine.volume_m = VOLUME[quality]
	engine.dirty = true


func _apply_preset(index: int) -> void:
	var p: Dictionary = presets()[index]
	set_function(p.text)
	function_text_changed.emit(p.text)


func set_function(text: String) -> String:
	return engine.set_field(text)


func get_function_spec() -> Dictionary:
	return {"label": "F(x, y, z) =", "text": engine.text, "variables": PackedStringArray(VectorFieldEngine.VARIABLES),
			"help": "Three components, e.g. (-y, x, 0). Use t for time, a and b for the sliders."}


func get_controls() -> Array:
	return [
		ControlSpec.choice("preset", "Field", preset_names(), _preset_index),
		ControlSpec.slider("a", "a", -3.0, 3.0, 0.05, engine.param_a),
		ControlSpec.slider("b", "b", -3.0, 3.0, 0.05, engine.param_b),
		ControlSpec.choice("view", "Volume", VIEWS, view_mode),
		ControlSpec.toggle("slice", "Slicing plane", show_slice),
		ControlSpec.choice("slice_mode", "Slice shows", SLICE_MODES, slice_mode),
		ControlSpec.choice("orientation", "Slice", ORIENTATIONS, orientation),
		ControlSpec.slider("slice_pos", "Slice at", -EXTENT, EXTENT, 0.05, slice_pos),
		ControlSpec.choice("axis", "Wheel axis", AXES, axis_mode),
		ControlSpec.toggle("arrows", "Arrows", show_arrows),
		ControlSpec.toggle("particles", "Flow particles", show_particles),
	]


func on_control(id: String, value: Variant) -> void:
	match id:
		"preset":
			select_preset(value)
		"a":
			set_params(value, engine.param_b)
		"b":
			set_params(engine.param_a, value)
		"view":
			view_mode = value
		"slice":
			show_slice = value
		"slice_mode":
			slice_mode = value
		"orientation":
			_set_orientation(value)
		"slice_pos":
			set_slice_pos(value)
		"axis":
			axis_mode = value
			_apply_axis()
		"arrows":
			show_arrows = value
		"particles":
			show_particles = value


## Normal of the slice orientation in math coordinates.
static func orientation_normal(index: int) -> Vector3:
	return [Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3(1, 0, 0)][index]


func _set_orientation(index: int) -> void:
	orientation = index
	var n := MeshUtil.to_godot(orientation_normal(index))
	# The quad faces its local +z: rotate +z onto n.
	var basis := Basis.looking_at(-n, Vector3.UP if absf(n.y) < 0.9 else Vector3.FORWARD)
	var origin := n * slice_pos
	_slice.set_local_constrained(Transform3D(basis, origin))


func set_slice_pos(value: float) -> void:
	slice_pos = clampf(value, -EXTENT, EXTENT)
	var n := _slice.transform.basis.z.normalized()
	var origin := _slice.transform.origin
	origin = origin - n * origin.dot(n) + n * slice_pos
	_slice.set_local_constrained(Transform3D(_slice.transform.basis, origin))


func _on_slice_moved() -> void:
	var n := _slice.transform.basis.z.normalized()
	var p := _slice.transform.origin.dot(n)
	if not is_equal_approx(p, slice_pos):
		slice_pos = p
		control_value_changed.emit("slice_pos", snappedf(p, 0.05))


func _apply_axis() -> void:
	if axis_mode < 3:
		var axis := MeshUtil.to_godot([Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)][axis_mode])
		_probe.set_local_constrained(Transform3D(_basis_y(axis), _probe.position))


static func _basis_y(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var ref := Vector3.RIGHT if absf(y.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var x := y.cross(ref).normalized()
	return Basis(x, y, x.cross(y))


func probe_math() -> Vector3:
	return MeshUtil.to_math(_probe.position)


func set_probe_math(p: Vector3) -> void:
	_probe.set_local_constrained(Transform3D(_probe.transform.basis, MeshUtil.to_godot(p)))


## Wheel axis in math coordinates (the probe's local up).
func wheel_axis() -> Vector3:
	return MeshUtil.to_math(_probe.transform.basis.y).normalized()


func handle_nudge(axis: Vector2, delta: float) -> void:
	set_probe_math(probe_math() + Vector3(axis.x, axis.y, 0.0) * 1.5 * delta)


func handle_scroll(steps: float) -> void:
	set_slice_pos(slice_pos + steps * 0.1)
	control_value_changed.emit("slice_pos", slice_pos)


func handle_action() -> void:
	view_mode = (view_mode + 1) % VIEWS.size()
	control_value_changed.emit("view", view_mode)


func get_hint() -> String:
	return "Drag the probe: the wheel spins at ½ curl·axis, the sphere tests Gauss, the loop tests Stokes.\n" \
			+ "Drag the slice handle (VR: turn it with your hand). Wheel: slice position. Space: volume view."


## Flux of F out of the sphere |q - p| = r (Fibonacci-sphere quadrature).
func flux_through_sphere(p: Vector3, r: float) -> float:
	var total := 0.0
	var golden := PI * (3.0 - sqrt(5.0))
	for i in SPHERE_SAMPLES:
		var y := 1.0 - 2.0 * (i + 0.5) / SPHERE_SAMPLES
		var rad := sqrt(1.0 - y * y)
		var n := Vector3(cos(golden * i) * rad, y, sin(golden * i) * rad)
		total += engine.field(p + n * r).dot(n)
	return total * 4.0 * PI * r * r / SPHERE_SAMPLES


## Circulation ∮ F · dr around the circle of radius r centred at p, normal n
## (counter-clockwise seen from the tip of n), midpoint rule.
func circulation(p: Vector3, n: Vector3, r: float) -> float:
	var e1 := n.cross(Vector3(1, 0, 0) if absf(n.x) < 0.9 else Vector3(0, 1, 0)).normalized()
	var e2 := n.cross(e1)
	var total := 0.0
	for i in LOOP_SAMPLES:
		var a := TAU * (i + 0.5) / LOOP_SAMPLES
		var q := p + (e1 * cos(a) + e2 * sin(a)) * r
		var tangent := (-e1 * sin(a) + e2 * cos(a)) * (TAU * r / LOOP_SAMPLES)
		total += engine.field(q).dot(tangent)
	return total


func _update_topic(delta: float) -> void:
	engine.particles_enabled = show_particles
	_particles.visible = show_particles
	_arrows.visible = show_arrows
	_volume.visible = view_mode < 2
	_volume_mat.set_shader_parameter("mode", view_mode)
	_slice.visible = show_slice
	_slice_mat.set_shader_parameter("mode", slice_mode)
	_slice_mat.set_shader_parameter("world_to_volume", _volume.global_transform.affine_inverse())
	var n_math := MeshUtil.to_math(_slice.transform.basis.z).normalized()
	_slice_mat.set_shader_parameter("normal_math", n_math)
	if engine.exprs.is_empty():
		return
	var p := probe_math()
	if axis_mode == 3:
		var c := engine.curl(p)
		if c.length() > 1e-6:
			_probe.transform.basis = _basis_y(MeshUtil.to_godot(c))
	var axis := wheel_axis()
	var dc := engine.div_curl(p)
	var curl_v: Vector3 = dc[1]
	# Angular velocity of a tiny paddle wheel = half the curl component along its axis.
	var omega := 0.5 * curl_v.dot(axis)
	wheel_angle = fmod(wheel_angle + omega * delta, TAU)
	_wheel.transform.basis = Basis(Vector3.UP, wheel_angle)
	_integral_timer -= delta
	if _integral_timer <= 0.0:
		update_integrals()
	_loop.transform = Transform3D(_probe.transform.basis, _probe.position)
	_probe_label.position = _probe.position + Vector3(0.45, 0.35, 0.0)
	_probe_label.text = "div F = %.3f\ncurl F = %s\nwheel ω = ½ curl·axis = %.2f rad/s" % [
			dc[0], Topic.fmt3(curl_v), omega]


## Gauss and Stokes checks at the probe (numerical surface/line integrals).
func update_integrals() -> void:
	_integral_timer = 0.1
	var p := probe_math()
	var axis := wheel_axis()
	var dc := engine.div_curl(p)
	var curl_v: Vector3 = dc[1]
	var volume := 4.0 / 3.0 * PI * PROBE_R ** 3
	gauss = {"flux": flux_through_sphere(p, PROBE_R), "div_times_volume": dc[0] * volume, "div": dc[0]}
	var area := PI * PROBE_R ** 2
	stokes = {"circulation": circulation(p, axis, PROBE_R), "curl_n_times_area": curl_v.dot(axis) * area,
			"omega": 0.5 * curl_v.dot(axis)}


func _bind_outputs() -> void:
	var stats := engine.get_output("stats")
	var volume := engine.get_output("volume")
	Topic.bind_texture(_volume_mat, "volume_tex", volume)
	Topic.bind_texture(_volume_mat, "stats_tex", stats)
	Topic.bind_texture(_slice_mat, "volume_tex", volume)
	Topic.bind_texture(_slice_mat, "stats_tex", stats)
	Topic.bind_texture(_arrow_mat, "data_tex", engine.get_output("field"))
	Topic.bind_texture(_arrow_mat, "stats_tex", stats)
	Topic.bind_texture(_particle_mat, "particle_tex", engine.get_output("particles"))


func _make_readout() -> String:
	if gauss.is_empty():
		return engine.text
	return ("F = %s\nAt the probe %s:\n" % [engine.text, Topic.fmt3(probe_math())]
		+ "Gauss: flux out of sphere = %.4f   div F × volume = %.4f\n" % [gauss.flux, gauss.div_times_volume]
		+ "Stokes: circulation = %.4f   (curl F·n) × area = %.4f\n" % [stokes.circulation, stokes.curl_n_times_area]
		+ "Colour scale: |div F| ≤ %.2f, |curl F| ≤ %.2f\n\n%s" % [engine.max_divergence, engine.max_curl, explanation()])


func workload() -> Dictionary:
	var w := {"voxels (div+curl)": engine.volume_m ** 3, "arrows": ARROW_GRID ** 3}
	if show_particles:
		w["particles"] = engine.particle_count
	return w


func get_debug_state() -> Dictionary:
	return {"probe": probe_math(), "axis": wheel_axis(), "gauss": gauss, "stokes": stokes,
			"wheel_angle": wheel_angle, "slice_pos": slice_pos, "volume_m": engine.volume_m}
