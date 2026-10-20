class_name XRLocomotion
extends Node
## Thumbstick locomotion: left stick walks (head-relative), right stick X
## snap-turns 30°, right stick Y flies up/down. B/Y resets the position.
## Snap turning (no smooth rotation) keeps it comfortable.

const MOVE_SPEED := 1.5
const FLY_SPEED := 1.0
const SNAP_ANGLE := deg_to_rad(30.0)
const DEADZONE := 0.2
const SNAP_THRESHOLD := 0.7
const SNAP_REARM := 0.3

var enabled := false
var origin: XROrigin3D
var camera: XRCamera3D
var left_hand: XRController3D
var right_hand: XRController3D

var _snap_armed := true
var _home: Transform3D


func setup(p_origin: XROrigin3D, p_camera: XRCamera3D, p_left: XRController3D, p_right: XRController3D) -> void:
	origin = p_origin
	camera = p_camera
	left_hand = p_left
	right_hand = p_right
	_home = origin.global_transform
	left_hand.button_pressed.connect(_on_button)
	right_hand.button_pressed.connect(_on_button)


func reset() -> void:
	origin.global_transform = _home


func _process(delta: float) -> void:
	if not enabled:
		return
	var move := left_hand.get_vector2("primary")
	if move.length() > DEADZONE:
		var forward := -camera.global_basis.z
		forward.y = 0.0
		forward = forward.normalized()
		var right := Vector3(-forward.z, 0.0, forward.x)
		origin.global_position += (right * move.x + forward * move.y) * MOVE_SPEED * delta
	var turn := right_hand.get_vector2("primary")
	if absf(turn.y) > DEADZONE and absf(turn.y) > absf(turn.x):
		origin.global_position.y = clampf(origin.global_position.y + turn.y * FLY_SPEED * delta, -1.0, 4.0)
	if _snap_armed and absf(turn.x) > SNAP_THRESHOLD:
		_snap_turn(-signf(turn.x) * SNAP_ANGLE)
		_snap_armed = false
	elif absf(turn.x) < SNAP_REARM:
		_snap_armed = true


## Rotates the origin around the player's head, so the head stays in place.
func _snap_turn(angle: float) -> void:
	var pivot := camera.global_position
	pivot.y = origin.global_position.y
	var rotation := Transform3D(Basis(Vector3.UP, angle), Vector3.ZERO)
	origin.global_transform = Transform3D.IDENTITY.translated(pivot) * rotation \
			* Transform3D.IDENTITY.translated(-pivot) * origin.global_transform


func _on_button(action: String) -> void:
	if enabled and action == "by_button":
		reset()
