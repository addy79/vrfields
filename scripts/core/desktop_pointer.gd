class_name DesktopPointer
extends Node
## Desktop stand-in for a VR controller: left click grabs / presses whatever is
## under the mouse cursor (or under the crosshair while mouse-look is active).

var camera: Camera3D
var pointer := PointerState.new()
var enabled := true:
	set(value):
		enabled = value
		if not enabled:
			pointer.release()


func _process(_delta: float) -> void:
	if enabled and camera:
		_update_ray(_screen_point(get_viewport().get_mouse_position()))


func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if not enabled or not button or button.button_index != MOUSE_BUTTON_LEFT:
		return
	if button.pressed:
		_update_ray(_screen_point(button.position))
		pointer.press()
	else:
		pointer.release()


func _screen_point(mouse_position: Vector2) -> Vector2:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return get_viewport().get_visible_rect().size * 0.5
	return mouse_position


func _update_ray(screen_point: Vector2) -> void:
	var origin := camera.project_ray_origin(screen_point)
	var dir := camera.project_ray_normal(screen_point)
	var pose := Transform3D(camera.global_basis, origin)
	pointer.update(camera.get_world_3d(), pose, dir)
