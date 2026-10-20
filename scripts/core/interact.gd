class_name Interact
extends RefCounted
## Pointer protocol shared by the desktop mouse and the VR controllers.
## An interactable node (or an ancestor of the collider that was hit) implements:
##   pointer_pressed(event: PointerEvent)
##   pointer_dragged(event: PointerEvent)     (optional)
##   pointer_released()                       (optional)
##   pointer_hover(hovering: bool)            (optional)

const RAY_LENGTH := 30.0


class PointerEvent:
	extends RefCounted
	var collider: Node
	var hit_position := Vector3.ZERO
	var ray_origin := Vector3.ZERO
	var ray_dir := Vector3.FORWARD
	## Full pose of the pointing device (controller, or the desktop camera).
	var pose := Transform3D.IDENTITY
	## True for a VR controller: grabbed objects may follow its rotation.
	var is_xr := false


## Walks up from the collider to the nearest node that accepts pointer presses.
static func find_target(collider: Object) -> Node:
	var node := collider as Node
	while node:
		if node.has_method("pointer_pressed"):
			return node
		node = node.get_parent()
	return null


static func raycast(world: World3D, origin: Vector3, dir: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * RAY_LENGTH)
	query.collide_with_areas = true
	return world.direct_space_state.intersect_ray(query)
