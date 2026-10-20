class_name Slider3D
extends StaticBody3D
## A horizontal 3D slider: press anywhere on the track and drag.

signal value_changed(value: float)

var min_value := 0.0
var max_value := 1.0
var step := 0.0
var value := 0.0
var length := 0.4

var _knob := MeshInstance3D.new()
var _fill := MeshInstance3D.new()
var _knob_material := MeshUtil.flat_material(Color(0.9, 0.92, 1.0))
var _dragging := false


func _init(p_min: float, p_max: float, p_step: float, p_value: float, p_length := 0.4) -> void:
	min_value = p_min
	max_value = p_max
	step = p_step
	length = p_length
	var track := MeshInstance3D.new()
	var track_mesh := BoxMesh.new()
	track_mesh.size = Vector3(length, 0.014, 0.01)
	track_mesh.material = MeshUtil.flat_material(Color(0.12, 0.14, 0.2))
	track.mesh = track_mesh
	add_child(track)
	var fill_mesh := BoxMesh.new()
	fill_mesh.size = Vector3(1.0, 0.016, 0.012)
	fill_mesh.material = MeshUtil.flat_material(Color(0.3, 0.6, 1.0))
	_fill.mesh = fill_mesh
	add_child(_fill)
	var knob_mesh := SphereMesh.new()
	knob_mesh.radius = 0.017
	knob_mesh.height = 0.034
	knob_mesh.material = _knob_material
	_knob.mesh = knob_mesh
	add_child(_knob)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(length + 0.04, 0.05, 0.03)
	shape.shape = box
	add_child(shape)
	set_value(p_value, false)


func set_value(v: float, emit := true) -> void:
	if step > 0.0:
		v = snappedf(v, step)
	v = clampf(v, min_value, max_value)
	var changed := not is_equal_approx(v, value)
	value = v
	var f := (value - min_value) / maxf(max_value - min_value, 1e-9)
	var x := -length * 0.5 + length * f
	_knob.position = Vector3(x, 0.0, 0.008)
	_fill.scale = Vector3(maxf(length * f, 0.001), 1.0, 1.0)
	_fill.position = Vector3(-length * 0.5 + length * f * 0.5, 0.0, 0.002)
	if changed and emit:
		value_changed.emit(value)


func pointer_hover(hovering: bool) -> void:
	_knob_material.emission_enabled = hovering or _dragging
	_knob_material.emission = Color(0.3, 0.6, 1.0)


func pointer_pressed(event: Interact.PointerEvent) -> void:
	_dragging = true
	_set_from_ray(event.ray_origin, event.ray_dir)


func pointer_dragged(event: Interact.PointerEvent) -> void:
	if _dragging:
		_set_from_ray(event.ray_origin, event.ray_dir)


func pointer_released() -> void:
	_dragging = false


func _set_from_ray(origin: Vector3, dir: Vector3) -> void:
	# Intersect the ray with the slider's plane, read the local x.
	var plane := Plane(global_basis.z.normalized(), global_position)
	var hit: Variant = plane.intersects_ray(origin, dir)
	if hit == null:
		return
	var local := to_local(hit)
	set_value(min_value + (local.x / length + 0.5) * (max_value - min_value))
