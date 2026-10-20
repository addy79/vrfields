class_name VectorFieldTopic
extends Topic
## 3D vector field F(x, y, z): a GPU-driven arrow grid coloured by |F|, flow
## particles advected on the GPU (RK4), field lines from a movable rake, and a
## probe that reads F, div F and curl F where you put it. Holding the probe with
## "Inject dye" on releases particles from it (streaklines).

const EXTENT := 2.0
const GRID := [6, 10, 14, 32]
const PARTICLES := [2048, 8192, 32768, 65536]
const LINE_SEEDS := 9
const LINE_STEPS := 110
const RAKE_HALF := 0.9
const FILTERS: PackedStringArray = ["All arrows", "Slab at probe height", "Near the probe"]

var engine := VectorFieldEngine.new()
var show_arrows := true
var show_particles := true
var show_lines := false
var inject_dye := false
var arrow_filter := 0

var _arrows := MultiMeshInstance3D.new()
var _arrow_mat := Topic.shader_material("res://shaders/arrows.gdshader")
var _particles := MultiMeshInstance3D.new()
var _particle_mat := Topic.shader_material("res://shaders/particles.gdshader")
var _lines := MeshInstance3D.new()
var _line_mat := Topic.shader_material("res://shaders/lines.gdshader")
var _probe := Grabbable.new("sphere", Vector3(0.1, 0, 0), Color(1, 1, 1))
var _probe_arrow := MeshUtil.make_arrow(Color(1.0, 0.35, 0.85), 0.03)
var _probe_label := MeshUtil.label("", 34)
var _rake := Grabbable.new("box", Vector3(RAKE_HALF * 2.0, 0.08, 0.08), Color(0.9, 0.9, 0.3))


func _init() -> void:
	topic_title = "Vector Fields"


func engines() -> Array[FieldEngine]:
	return [engine]


func presets() -> Array[Dictionary]:
	return FieldPresets.LIST


func _build() -> void:
	engine.extent = EXTENT
	engine.line_seeds = LINE_SEEDS
	engine.line_steps = LINE_STEPS
	engine.line_step_len = 0.05
	plot.add_child(Topic.make_box_and_axes(EXTENT))
	var big := AABB(Vector3.ONE * -EXTENT * 1.6, Vector3.ONE * EXTENT * 3.2)

	_arrows.material_override = _arrow_mat
	_arrows.custom_aabb = big
	_arrow_mat.set_shader_parameter("extent", EXTENT)
	plot.add_child(_arrows)

	var quad := QuadMesh.new()
	_particles.material_override = _particle_mat
	_particles.custom_aabb = big
	_particles.multimesh = MeshUtil.identity_multimesh(quad, 0)
	_particle_mat.set_shader_parameter("width", 0.005)
	_particle_mat.set_shader_parameter("streak", 0.03)
	plot.add_child(_particles)

	_lines.mesh = MeshUtil.ribbon_mesh(LINE_STEPS * 2 + 1, LINE_SEEDS)
	_lines.material_override = _line_mat
	_lines.custom_aabb = big
	_line_mat.set_shader_parameter("points", LINE_STEPS * 2 + 1)
	_line_mat.set_shader_parameter("width", 0.004)
	plot.add_child(_lines)

	var box_limit := func(local: Transform3D) -> Transform3D:
		local.origin = local.origin.clamp(Vector3.ONE * -EXTENT, Vector3.ONE * EXTENT)
		return local
	_probe.constrain = box_limit
	_probe.position = MeshUtil.to_godot(Vector3(1.0, 0.5, 0.6))
	_probe.moved.connect(_on_probe_moved)
	plot.add_child(_probe)
	plot.add_child(_probe_arrow)
	_probe_label.pixel_size = 0.0035
	_probe_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	plot.add_child(_probe_label)

	_rake.constrain = box_limit
	_rake.follow_rotation = true
	_rake.position = MeshUtil.to_godot(Vector3(-1.2, 0.0, -0.8))
	_rake.moved.connect(_update_seeds)
	plot.add_child(_rake)
	_update_seeds()


func apply_quality() -> void:
	engine.grid_n = GRID[quality]
	engine.particle_count = PARTICLES[quality]
	var n: int = GRID[quality]
	if _arrows.multimesh == null or _arrows.multimesh.instance_count != n * n * n:
		_arrows.multimesh = MeshUtil.identity_multimesh(MeshUtil.arrow_mesh(), n * n * n)
	if _particles.multimesh.instance_count != engine.particle_count:
		_particles.multimesh = MeshUtil.identity_multimesh(_particles.multimesh.mesh, engine.particle_count)
	_arrow_mat.set_shader_parameter("grid_n", n)
	_particle_mat.set_shader_parameter("rows", engine.particle_rows())
	engine.dirty = true


func _apply_preset(index: int) -> void:
	var p: Dictionary = presets()[index]
	set_function(p.text)
	function_text_changed.emit(p.text)


func set_function(text: String) -> String:
	var error := engine.set_field(text)
	if error.is_empty():
		_on_probe_moved()
	return error


func get_function_spec() -> Dictionary:
	return {"label": "F(x, y, z) =", "text": engine.text, "variables": PackedStringArray(VectorFieldEngine.VARIABLES),
			"help": "Three components, e.g. (-y, x, 0). Use t for time, a and b for the sliders."}


func get_controls() -> Array:
	return [
		ControlSpec.choice("preset", "Field", preset_names(), _preset_index),
		ControlSpec.slider("a", "a", -3.0, 3.0, 0.05, engine.param_a),
		ControlSpec.slider("b", "b", -3.0, 3.0, 0.05, engine.param_b),
		ControlSpec.toggle("arrows", "Arrows (|F| colour)", show_arrows),
		ControlSpec.toggle("particles", "Flow particles", show_particles),
		ControlSpec.toggle("lines", "Field lines from rake", show_lines),
		ControlSpec.toggle("dye", "Inject dye at probe", inject_dye),
		ControlSpec.choice("filter", "Show", FILTERS, arrow_filter),
		ControlSpec.slider("speed", "Flow speed", 0.2, 3.0, 0.1, engine.flow_speed, "%.1f"),
	]


func on_control(id: String, value: Variant) -> void:
	match id:
		"preset":
			select_preset(value)
		"a":
			set_params(value, engine.param_b)
			_on_probe_moved()
		"b":
			set_params(engine.param_a, value)
			_on_probe_moved()
		"arrows":
			show_arrows = value
		"particles":
			show_particles = value
		"lines":
			show_lines = value
			engine.dirty = true
		"dye":
			inject_dye = value
		"filter":
			arrow_filter = value
		"speed":
			engine.flow_speed = value


func probe_math() -> Vector3:
	return MeshUtil.to_math(_probe.position)


func set_probe_math(p: Vector3) -> void:
	_probe.set_local_constrained(Transform3D(Basis.IDENTITY, MeshUtil.to_godot(p)))


func handle_nudge(axis: Vector2, delta: float) -> void:
	set_probe_math(probe_math() + Vector3(axis.x, axis.y, 0.0) * 1.5 * delta)


func handle_scroll(steps: float) -> void:
	set_probe_math(probe_math() + Vector3(0.0, 0.0, steps * 0.1))


func handle_action() -> void:
	show_particles = not show_particles
	control_value_changed.emit("particles", show_particles)


func get_hint() -> String:
	return "Drag the white probe (or arrow keys + wheel) to read F, div F and curl F.\n" \
			+ "Drag the yellow rake to seed field lines (VR: it turns with your hand). Space: particles."


func _update_seeds() -> void:
	var seeds := PackedVector3Array()
	var x_axis := _rake.transform.basis.x.normalized()
	for i in LINE_SEEDS:
		var f := lerpf(-RAKE_HALF, RAKE_HALF, float(i) / (LINE_SEEDS - 1))
		seeds.append(MeshUtil.to_math(_rake.position + x_axis * f))
	engine.set_seeds(seeds)


func _on_probe_moved() -> void:
	if engine.exprs.is_empty():
		return
	var p := probe_math()
	var f := engine.field(p)
	MeshUtil.set_arrow(_probe_arrow, MeshUtil.to_godot(f) * (0.9 / maxf(engine.max_magnitude, 1e-6)))
	_probe_arrow.position = _probe.position
	var dc := engine.div_curl(p)
	_probe_label.position = _probe.position + Vector3(0.18, 0.25, 0.0)
	_probe_label.text = "F = %s\n|F| = %.2f\ndiv F = %.2f\ncurl F = %s" % [Topic.fmt3(f), f.length(), dc[0], Topic.fmt3(dc[1])]


func _update_topic(_delta: float) -> void:
	engine.arrows_enabled = show_arrows
	engine.particles_enabled = show_particles or inject_dye
	engine.lines_enabled = show_lines
	_arrows.visible = show_arrows
	_particles.visible = engine.particles_enabled
	_lines.visible = show_lines
	_rake.visible = show_lines
	engine.emitter = probe_math()
	engine.emitter_radius = 0.12 if inject_dye else 0.0
	engine.emitter_fraction = 0.35 if show_particles else 1.0
	_arrow_mat.set_shader_parameter("slab_axis", 3 if arrow_filter == 1 else 0)
	_arrow_mat.set_shader_parameter("slab_pos", probe_math().z)
	_arrow_mat.set_shader_parameter("slab_half", EXTENT / (GRID[quality] - 1) * 0.6)
	_arrow_mat.set_shader_parameter("focus", probe_math())
	_arrow_mat.set_shader_parameter("focus_radius", 1.0 if arrow_filter == 2 else 0.0)
	if engine.is_time_dependent():
		_on_probe_moved()


func _bind_outputs() -> void:
	Topic.bind_texture(_arrow_mat, "data_tex", engine.get_output("field"))
	Topic.bind_texture(_arrow_mat, "stats_tex", engine.get_output("stats"))
	Topic.bind_texture(_particle_mat, "particle_tex", engine.get_output("particles"))
	Topic.bind_texture(_line_mat, "line_tex", engine.get_output("lines"))


func _make_readout() -> String:
	return "F(x, y, z) = %s\nColour: |F| from 0 (blue) to %.2f (red)\n\n%s" % [
			engine.text, engine.max_magnitude, explanation()]


func workload() -> Dictionary:
	var w := {"arrows": engine.grid_n ** 3}
	if engine.particles_enabled:
		w["particles"] = engine.particle_count
	if show_lines:
		w["field-line points"] = LINE_SEEDS * (LINE_STEPS * 2 + 1)
	return w


func get_debug_state() -> Dictionary:
	return {"probe": probe_math(), "label": _probe_label.text, "grid_n": engine.grid_n,
			"particles": engine.particle_count, "arrow_instances": _arrows.multimesh.instance_count}
