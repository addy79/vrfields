class_name FreeFlyCamera
extends Camera3D
## Desktop camera: WASD fly, Q/E down/up, Shift faster, hold right mouse to look.

@export var move_speed := 2.0
@export var sprint_multiplier := 3.0
@export var acceleration := 10.0
@export var mouse_sensitivity := 0.0025

var enabled := true:
	set(value):
		enabled = value
		if not enabled and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
## Set while a text box has focus, so typed letters don't move the camera.
var typing := false

var _yaw := 0.0
var _pitch := 0.0
var _velocity := Vector3.ZERO


func reset_view(pos: Vector3, target: Vector3) -> void:
	global_position = pos
	_velocity = Vector3.ZERO
	look_at(target)
	var euler := basis.get_euler()
	_pitch = euler.x
	_yaw = euler.y


func _unhandled_input(event: InputEvent) -> void:
	if not enabled:
		return
	var button := event as InputEventMouseButton
	if button and button.button_index == MOUSE_BUTTON_RIGHT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if button.pressed else Input.MOUSE_MODE_VISIBLE
		return
	var motion := event as InputEventMouseMotion
	if motion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= motion.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - motion.relative.y * mouse_sensitivity, -1.5, 1.5)
		basis = Basis.from_euler(Vector3(_pitch, _yaw, 0.0))


func _process(delta: float) -> void:
	if not enabled:
		return
	var input := Vector3.ZERO if typing else Vector3(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_down", "move_up"),
		Input.get_axis("move_forward", "move_back"))
	var dir := basis * Vector3(input.x, 0.0, input.z) + Vector3.UP * input.y
	if dir.length_squared() > 1.0:
		dir = dir.normalized()
	var speed := move_speed * (sprint_multiplier if Input.is_action_pressed("sprint") else 1.0)
	_velocity = _velocity.lerp(dir * speed, 1.0 - exp(-acceleration * delta))
	global_position += _velocity * delta


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
