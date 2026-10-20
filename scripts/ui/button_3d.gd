class_name Button3D
extends StaticBody3D
## A pressable 3D button for the laser pointer and the mouse.

signal pressed

const COLOR_IDLE := Color(0.16, 0.19, 0.27)
const COLOR_HOVER := Color(0.26, 0.36, 0.55)
const COLOR_SELECTED := Color(0.93, 0.55, 0.16)

var selected := false:
	set(value):
		selected = value
		_refresh()
var text := "":
	set(value):
		text = value
		_label.text = value

var _hovered := false
var _material := StandardMaterial3D.new()
var _mesh := MeshInstance3D.new()
var _label := Label3D.new()


func _init(p_text: String = "Button", size := Vector2(0.3, 0.075), font_size := 28) -> void:
	var box := BoxMesh.new()
	box.size = Vector3(size.x, size.y, 0.015)
	box.material = _material
	_mesh.mesh = box
	add_child(_mesh)
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = box.size
	shape.shape = box_shape
	add_child(shape)
	_label.font = MeshUtil.math_font()
	_label.font_size = font_size
	_label.pixel_size = 0.001
	_label.outline_size = 0
	_label.position = Vector3(0.0, 0.0, 0.009)
	_label.render_priority = 2
	_label.width = size.x / _label.pixel_size
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	add_child(_label)
	text = p_text
	_refresh()


func pointer_hover(hovering: bool) -> void:
	_hovered = hovering
	_refresh()


func pointer_pressed(_event: Interact.PointerEvent) -> void:
	var tween := create_tween()
	tween.tween_property(_mesh, "position:z", -0.006, 0.05)
	tween.tween_property(_mesh, "position:z", 0.0, 0.08)
	pressed.emit()


func _refresh() -> void:
	if selected:
		_material.albedo_color = COLOR_SELECTED
	else:
		_material.albedo_color = COLOR_HOVER if _hovered else COLOR_IDLE
	_material.emission_enabled = _hovered
	_material.emission = Color(0.2, 0.3, 0.5)
