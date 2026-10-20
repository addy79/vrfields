class_name Grabbable
extends StaticBody3D
## A handle that can be grabbed with the laser (trigger / left click) or by hand
## (VR grip). With the mouse it slides along the view at a fixed distance; in VR
## it follows the controller's full pose, so it can also be turned (slice planes,
## the paddle wheel). `constrain` limits the result in the parent's space.

signal moved
signal grab_changed(is_grabbed: bool)

## Callable(Transform3D local) -> Transform3D, applied after every move.
var constrain: Callable
## Follow the controller's rotation in VR.
var follow_rotation := false
## Desktop drags slide on a plane through the grab point (normal in the
## parent's space) instead of keeping a fixed distance from the camera.
var drag_plane := false
var drag_plane_normal := Vector3.UP
var grabbed := false

var _offset := Transform3D.IDENTITY   # pointer pose -> object (global)
var _distance := 0.0
var _hit_offset := Vector3.ZERO
var _material := StandardMaterial3D.new()
var _visual: MeshInstance3D


## shape: "sphere" (size.x = radius) or "box" (size = extents).
func _init(shape: String = "sphere", size := Vector3(0.1, 0.1, 0.1), color := Color.WHITE) -> void:
	_material.albedo_color = color
	_material.roughness = 0.3
	_visual = MeshInstance3D.new()
	var collision := CollisionShape3D.new()
	if shape == "box":
		var box := BoxMesh.new()
		box.size = size
		box.material = _material
		_visual.mesh = box
		var box_shape := BoxShape3D.new()
		box_shape.size = size * 1.2
		collision.shape = box_shape
	else:
		var sphere := SphereMesh.new()
		sphere.radius = size.x
		sphere.height = size.x * 2.0
		sphere.radial_segments = 24
		sphere.rings = 12
		sphere.material = _material
		_visual.mesh = sphere
		var sphere_shape := SphereShape3D.new()
		sphere_shape.radius = size.x * 1.5
		collision.shape = sphere_shape
	add_child(_visual)
	add_child(collision)


func set_color(color: Color) -> void:
	_material.albedo_color = color


func set_visual_visible(value: bool) -> void:
	_visual.visible = value


func pointer_hover(hovering: bool) -> void:
	_material.emission_enabled = hovering or grabbed
	_material.emission = Color(0.4, 0.8, 1.0)
	_material.emission_energy_multiplier = 0.6


func pointer_pressed(event: Interact.PointerEvent) -> void:
	grabbed = true
	_offset = event.pose.affine_inverse() * global_transform
	_distance = event.ray_origin.distance_to(event.hit_position)
	_hit_offset = global_position - event.hit_position
	grab_changed.emit(true)


func pointer_dragged(event: Interact.PointerEvent) -> void:
	if not grabbed:
		return
	var target := global_transform
	if event.is_xr:
		var follow := event.pose * _offset
		target.origin = follow.origin
		if follow_rotation:
			target.basis = follow.basis
	elif drag_plane:
		var parent := get_parent() as Node3D
		var normal := (parent.global_basis * drag_plane_normal).normalized() if parent else drag_plane_normal
		var plane := Plane(normal, global_position - _hit_offset)
		var hit: Variant = plane.intersects_ray(event.ray_origin, event.ray_dir)
		if hit == null:
			return
		target.origin = hit + _hit_offset
	else:
		target.origin = event.ray_origin + event.ray_dir * _distance + _hit_offset
	set_global_transform_constrained(target)


func pointer_released() -> void:
	grabbed = false
	pointer_hover(false)
	grab_changed.emit(false)


## Places the handle (global transform), applying the constraint.
func set_global_transform_constrained(target: Transform3D) -> void:
	var parent := get_parent() as Node3D
	var local := parent.global_transform.affine_inverse() * target if parent else target
	if constrain.is_valid():
		local = constrain.call(local)
	transform = local
	moved.emit()


## Same in the parent's space (used by keyboard/thumbstick nudges and tests).
func set_local_constrained(local: Transform3D) -> void:
	if constrain.is_valid():
		local = constrain.call(local)
	transform = local
	moved.emit()
