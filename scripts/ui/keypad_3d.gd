class_name Keypad3D
extends Node3D
## Floating keypad for typing functions in VR (laser + trigger on the keys).

signal submitted(text: String)
signal closed

const KEY := Vector2(0.085, 0.065)
const GAP := 0.008
const COLUMNS := 7

var text := ""

var _variables := PackedStringArray()
var _keys := Node3D.new()
var _board := MeshInstance3D.new()
var _title := Label3D.new()
var _display := Label3D.new()
var _status := Label3D.new()


func _ready() -> void:
	var board_mesh := BoxMesh.new()
	board_mesh.material = MeshUtil.flat_material(Color(0.04, 0.05, 0.08, 0.9))
	_board.mesh = board_mesh
	add_child(_board)
	for l: Label3D in [_title, _display, _status]:
		l.font = MeshUtil.math_font()
		l.pixel_size = 0.001
		l.outline_size = 0
		l.render_priority = 2
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		add_child(l)
	_title.font_size = 28
	_display.font_size = 30
	_display.modulate = Color(1.0, 0.95, 0.6)
	_display.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_display.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_status.font_size = 24
	add_child(_keys)
	visible = false


func open(label: String, value: String, variables: PackedStringArray) -> void:
	text = value
	_variables = variables
	_title.text = "Type   " + label
	_build()
	set_status("", Color.WHITE)
	visible = true
	_refresh()


func set_status(message: String, color: Color) -> void:
	_status.text = message
	_status.modulate = color


func _build() -> void:
	for child in _keys.get_children():
		child.queue_free()
	var keys: Array[String] = []
	for v in _variables:
		keys.append(v)
	while keys.size() % COLUMNS != 0:
		keys.append("")
	keys.append_array([
		"7", "8", "9", "(", ")", ",", "⌫",
		"4", "5", "6", "*", "/", "^", "C",
		"1", "2", "3", "+", "-", ".", "π",
		"0", "sin", "cos", "tan", "sqrt", "exp", "ln",
		"abs", "atan", "=", "..", "e", "max", "^2",
	])
	var width := COLUMNS * (KEY.x + GAP) - GAP
	var left := -width * 0.5 + KEY.x * 0.5
	var top := -0.14
	var row := 0
	for i in keys.size():
		var col := i % COLUMNS
		row = i / COLUMNS
		if keys[i].is_empty():
			continue
		_add_key(keys[i], Vector3(left + col * (KEY.x + GAP), top - row * (KEY.y + GAP), 0.0), KEY,
				_on_key.bind(keys[i]))
	var bottom := top - (row + 1) * (KEY.y + GAP) - 0.01
	var third := (width - 2.0 * GAP) / 3.0
	_add_key("Close ✕", Vector3(-width * 0.5 + third * 0.5, bottom, 0.0), Vector2(third, KEY.y), func() -> void:
		visible = false
		closed.emit())
	_add_key("Clear", Vector3(0.0, bottom, 0.0), Vector2(third, KEY.y), _on_key.bind("C"))
	_add_key("Plot ✓", Vector3(width * 0.5 - third * 0.5, bottom, 0.0), Vector2(third, KEY.y),
			func() -> void: submitted.emit(text))
	var height := -bottom + KEY.y * 0.5 + 0.1
	(_board.mesh as BoxMesh).size = Vector3(width + 0.05, height, 0.01)
	_board.position = Vector3(0.0, 0.07 - height * 0.5, -0.012)
	_title.position = Vector3(-width * 0.5, 0.04, 0.0)
	_display.position = Vector3(-width * 0.5, 0.0, 0.0)
	_display.width = width / _display.pixel_size
	_status.position = Vector3(-width * 0.5, -0.1, 0.0)


func _add_key(label: String, pos: Vector3, size: Vector2, callback: Callable) -> void:
	var key := Button3D.new(label, size, 26)
	key.position = pos
	key.pressed.connect(callback)
	_keys.add_child(key)


func _on_key(key: String) -> void:
	match key:
		"⌫":
			for fn in ["sqrt(", "sin(", "cos(", "tan(", "exp(", "abs(", "atan(", "ln("]:
				if text.ends_with(fn):
					text = text.left(-fn.length())
					_refresh()
					return
			text = text.left(-1)
		"C":
			text = ""
		"sin", "cos", "tan", "sqrt", "ln", "exp", "abs", "atan", "max":
			text += key + "("
		"π":
			text += "pi"
		_:
			text += key
	set_status("", Color.WHITE)
	_refresh()


func _refresh() -> void:
	_display.font_size = 30 if text.length() <= 40 else 22
	_display.text = text + "▏"
