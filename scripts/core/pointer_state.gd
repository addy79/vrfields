class_name PointerState
extends RefCounted
## Hover/press/drag state of one pointer (mouse or VR controller ray).

signal grabbed(target: Node)
signal released(target: Node)

var hovered: Node
var held: Node
var is_xr := false
var event := Interact.PointerEvent.new()
var has_hit := false


## Casts the ray, updates hover state and forwards drags to the held target.
func update(world: World3D, pose: Transform3D, dir: Vector3) -> void:
	var origin := pose.origin
	var hit := Interact.raycast(world, origin, dir)
	has_hit = not hit.is_empty()
	event = Interact.PointerEvent.new()
	event.is_xr = is_xr
	event.pose = pose
	event.ray_origin = origin
	event.ray_dir = dir
	event.collider = hit.collider as Node if has_hit else null
	event.hit_position = hit.position if has_hit else origin + dir * Interact.RAY_LENGTH
	var target := Interact.find_target(event.collider)
	if held and not is_instance_valid(held):
		held = null
	if held:
		if held.has_method("pointer_dragged"):
			held.pointer_dragged(event)
		target = held
	_set_hovered(target)


func press() -> void:
	if hovered and is_instance_valid(hovered):
		held = hovered
		held.pointer_pressed(event)
		grabbed.emit(held)


func release() -> void:
	if held and is_instance_valid(held):
		if held.has_method("pointer_released"):
			held.pointer_released()
		released.emit(held)
	held = null


func is_hovering() -> bool:
	return hovered != null and is_instance_valid(hovered)


func hit_distance() -> float:
	return event.ray_origin.distance_to(event.hit_position)


func _set_hovered(target: Node) -> void:
	if target == hovered:
		return
	if hovered and is_instance_valid(hovered) and hovered.has_method("pointer_hover"):
		hovered.pointer_hover(false)
	hovered = target
	if hovered and hovered.has_method("pointer_hover"):
		hovered.pointer_hover(true)
