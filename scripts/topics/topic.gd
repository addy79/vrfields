class_name Topic
extends Node3D
## Base class for the five calculus topics. main.gd forwards input through the
## hooks below so a topic works with keyboard/mouse and VR controllers alike.
## Each topic owns one or more FieldEngines (GPU compute + CPU baseline) and
## binds their output textures to its materials every frame.

## The topic changed one of its own controls (panels update their widgets).
signal control_value_changed(id: String, value: Variant)
## The function text changed (e.g. a preset was picked).
signal function_text_changed(text: String)
## Status line for compile errors etc.
signal message(text: String, is_error: bool)

const QUALITY_NAMES: PackedStringArray = ["Low", "Medium", "High", "Ultra"]

## Metres per math unit.
@export var plot_scale := 0.33
var topic_title := "Topic"
var quality := 1
var backend := FieldEngine.Backend.GPU
var time := 0.0
## Text shown on the readout board (refreshed ~10 times per second).
var readout := ""

var plot := Node3D.new()
var _preset_index := 0
var _readout_timer := 0.0


func _ready() -> void:
	plot.name = "Plot"
	plot.scale = Vector3.ONE * plot_scale
	add_child(plot)
	_build()
	for e in engines():
		e.compiled.connect(_on_compiled.bind(e))
		e.set_backend(backend)
	apply_quality()
	_apply_preset(_preset_index)


func _exit_tree() -> void:
	for e in engines():
		e.free_gpu()


func _process(delta: float) -> void:
	for e in engines():
		e.t = time
		e.update(delta)
	_bind_outputs()
	_update_topic(delta)
	_readout_timer -= delta
	if _readout_timer <= 0.0:
		_readout_timer = 0.1
		readout = _make_readout()


# --- Overridables -------------------------------------------------------------------------

func engines() -> Array[FieldEngine]:
	return []


## Build nodes (called once from _ready, after `plot` exists).
func _build() -> void:
	pass


func _bind_outputs() -> void:
	pass


func _update_topic(_delta: float) -> void:
	pass


func _make_readout() -> String:
	return ""


func presets() -> Array[Dictionary]:
	return []


## Apply preset i (sets the function text and parameters).
func _apply_preset(_index: int) -> void:
	pass


func apply_quality() -> void:
	pass


## Topic-specific controls (ControlSpec dictionaries).
func get_controls() -> Array:
	return []


func on_control(_id: String, _value: Variant) -> void:
	pass


## {"label", "text", "variables", "help"} for the function editor.
func get_function_spec() -> Dictionary:
	return {}


## Plots typed text; returns "" or an error message.
func set_function(_text: String) -> String:
	return "This topic has no editable function"


## Arrow keys (desktop) or right thumbstick with grip held (VR).
func handle_nudge(_axis: Vector2, _delta: float) -> void:
	pass


func handle_scroll(_steps: float) -> void:
	pass


func handle_action() -> void:
	pass


func get_hint() -> String:
	return ""


## What a preset teaches (shown with the readout).
func explanation() -> String:
	var list := presets()
	return list[_preset_index].get("note", "") if _preset_index < list.size() else ""


## Number of evaluated points per update, by output (for stats and benchmarks).
func workload() -> Dictionary:
	return {}


func get_debug_state() -> Dictionary:
	return {}


# --- Shared helpers -------------------------------------------------------------------------

func set_backend(value: FieldEngine.Backend) -> void:
	backend = value
	for e in engines():
		e.set_backend(value)


func set_quality(level: int) -> void:
	quality = clampi(level, 0, 3)
	apply_quality()
	for e in engines():
		e.dirty = true


func set_params(a: float, b: float) -> void:
	for e in engines():
		e.param_a = a
		e.param_b = b
		e.dirty = true


func preset_names() -> PackedStringArray:
	var names := PackedStringArray()
	for p in presets():
		names.append(p.name)
	return names


func select_preset(index: int) -> void:
	_preset_index = clampi(index, 0, presets().size() - 1)
	_apply_preset(_preset_index)
	control_value_changed.emit("preset", _preset_index)


func preset_index() -> int:
	return _preset_index


## Sets a shader parameter only when the texture object changed.
static func bind_texture(material: ShaderMaterial, param: String, tex: Texture) -> void:
	if tex and material.get_shader_parameter(param) != tex:
		material.set_shader_parameter(param, tex)


static func shader_material(path: String) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(path)
	return m


## Wire-frame cube [-e, e]³ in math units plus labelled axes.
static func make_box_and_axes(e: float) -> Node3D:
	var root := Node3D.new()
	var mesh := ImmediateMesh.new()
	var mat := MeshUtil.flat_material(Color(1, 1, 1, 0.25), true)
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for a in 3:
		for s1: float in [-1.0, 1.0]:
			for s2: float in [-1.0, 1.0]:
				var p := Vector3.ZERO
				var q := Vector3.ZERO
				p[a] = -e
				q[a] = e
				p[(a + 1) % 3] = s1 * e
				q[(a + 1) % 3] = s1 * e
				p[(a + 2) % 3] = s2 * e
				q[(a + 2) % 3] = s2 * e
				mesh.surface_add_vertex(p)
				mesh.surface_add_vertex(q)
	mesh.surface_end()
	var box := MeshInstance3D.new()
	box.mesh = mesh
	root.add_child(box)
	var names: Array[String] = ["x", "y", "z"]
	var colors: Array[Color] = [Color(1.0, 0.45, 0.45), Color(0.45, 1.0, 0.5), Color(0.5, 0.65, 1.0)]
	for i in 3:
		var dir_m := Vector3.ZERO
		dir_m[i] = 1.0
		var dir := MeshUtil.to_godot(dir_m)
		var arrow := MeshUtil.make_arrow(colors[i], 0.012)
		arrow.position = -dir * (e + 0.3)
		MeshUtil.set_arrow(arrow, dir * (2.0 * e + 0.6))
		root.add_child(arrow)
		var label := MeshUtil.label(names[i], 64)
		label.modulate = colors[i]
		label.position = dir * (e + 0.45)
		root.add_child(label)
	return root


func _on_compiled(error: String, engine: FieldEngine) -> void:
	if error.is_empty():
		return
	# A GLSL compile error should not happen for parser-checked input; if it
	# does, keep the app usable on the CPU path and say why.
	engine.set_backend(FieldEngine.Backend.CPU)
	message.emit("GPU compile failed, using the CPU for this function: " + error, true)


static func fmt3(v: Vector3, decimals := 2) -> String:
	var f := "%." + str(decimals) + "f"
	return ("(" + f + ", " + f + ", " + f + ")") % [v.x, v.y, v.z]
