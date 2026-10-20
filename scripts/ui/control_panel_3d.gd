class_name ControlPanel3D
extends Node3D
## Floating VR panel built from a ControlSpec list. Point the laser and pull the
## trigger on buttons; drag sliders. Emits control_changed(id, value).

signal control_changed(id: String, value: Variant)

const WIDTH := 0.66
const ROW := 0.07
const GAP := 0.012
const LABEL_W := 0.22

var _rows := Node3D.new()
var _board := MeshInstance3D.new()
var _title := Label3D.new()
## id -> {"spec", "widget", "value_label"}
var _widgets := {}


func _ready() -> void:
	var board_mesh := BoxMesh.new()
	board_mesh.material = MeshUtil.flat_material(Color(0.04, 0.05, 0.08, 0.88))
	_board.mesh = board_mesh
	add_child(_board)
	_title.font = MeshUtil.math_font()
	_title.font_size = 36
	_title.pixel_size = 0.001
	_title.outline_size = 0
	_title.render_priority = 2
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_title.position = Vector3(-WIDTH * 0.5, 0.0, 0.01)
	add_child(_title)
	add_child(_rows)


func build(title: String, specs: Array) -> void:
	_title.text = title
	_widgets.clear()
	for child in _rows.get_children():
		child.queue_free()
	var y := -ROW
	for spec: Dictionary in specs:
		y = _add_row(spec, y)
	var height := -y + ROW * 0.5
	(_board.mesh as BoxMesh).size = Vector3(WIDTH + 0.06, height, 0.01)
	_board.position = Vector3(0.0, -height * 0.5 + ROW * 0.6, -0.012)


## Updates a widget without emitting control_changed.
func set_value(id: String, value: Variant) -> void:
	if not _widgets.has(id):
		return
	var entry: Dictionary = _widgets[id]
	var spec: Dictionary = entry.spec
	spec.value = value
	match spec.type:
		"toggle":
			(entry.widget as Button3D).selected = value
		"choice":
			(entry.value_label as Label3D).text = spec.options[value]
		"slider":
			(entry.widget as Slider3D).set_value(value, false)
			(entry.value_label as Label3D).text = spec.format % value


## Global position of a widget (for tests driving the panel with the pointer).
func widget_position(id: String, part := "") -> Vector3:
	var entry: Dictionary = _widgets.get(id, {})
	if entry.is_empty():
		return Vector3.INF
	if part == "next" and entry.has("next"):
		return (entry.next as Node3D).global_position
	return (entry.widget as Node3D).global_position


## The four corners of the board in global space.
func get_corners() -> PackedVector3Array:
	var size: Vector3 = (_board.mesh as BoxMesh).size * 0.5
	var out := PackedVector3Array()
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			out.append(_board.global_transform * Vector3(size.x * sx, size.y * sy, 0.0))
	return out


func _text(s: String, font_size := 26, align := HORIZONTAL_ALIGNMENT_LEFT) -> Label3D:
	var l := Label3D.new()
	l.text = s
	l.font = MeshUtil.math_font()
	l.font_size = font_size
	l.pixel_size = 0.001
	l.outline_size = 0
	l.render_priority = 2
	l.horizontal_alignment = align
	return l


func _add_row(spec: Dictionary, y: float) -> float:
	var left := -WIDTH * 0.5
	var right_w := WIDTH - LABEL_W
	var right_c := left + LABEL_W + right_w * 0.5
	match spec.type:
		"header":
			var l := _text(spec.label, 30)
			l.modulate = Color(0.6, 0.8, 1.0)
			l.position = Vector3(left, y - 0.01, 0.0)
			_rows.add_child(l)
			return y - ROW * 0.8
		"button":
			var b := Button3D.new(spec.label, Vector2(WIDTH, ROW))
			b.position = Vector3(0.0, y, 0.0)
			b.pressed.connect(func() -> void: control_changed.emit(spec.id, true))
			_rows.add_child(b)
			_widgets[spec.id] = {"spec": spec, "widget": b}
		"toggle":
			var b := Button3D.new(spec.label, Vector2(WIDTH, ROW))
			b.position = Vector3(0.0, y, 0.0)
			b.selected = spec.value
			b.pressed.connect(func() -> void:
				spec.value = not spec.value
				b.selected = spec.value
				control_changed.emit(spec.id, spec.value))
			_rows.add_child(b)
			_widgets[spec.id] = {"spec": spec, "widget": b}
		"choice":
			var l := _text(spec.label)
			l.position = Vector3(left, y, 0.0)
			_rows.add_child(l)
			var arrow_w := 0.06
			var prev := Button3D.new("◀", Vector2(arrow_w, ROW))
			prev.position = Vector3(left + LABEL_W + arrow_w * 0.5, y, 0.0)
			var next := Button3D.new("▶", Vector2(arrow_w, ROW))
			next.position = Vector3(WIDTH * 0.5 - arrow_w * 0.5, y, 0.0)
			var value_label := _text(spec.options[spec.value], 24, HORIZONTAL_ALIGNMENT_CENTER)
			value_label.position = Vector3(right_c, y, 0.0)
			value_label.width = (right_w - 2.0 * arrow_w) / value_label.pixel_size
			value_label.autowrap_mode = TextServer.AUTOWRAP_OFF
			var step := func(d: int) -> void:
				spec.value = posmod(spec.value + d, spec.options.size())
				value_label.text = spec.options[spec.value]
				control_changed.emit(spec.id, spec.value)
			prev.pressed.connect(step.bind(-1))
			next.pressed.connect(step.bind(1))
			for n: Node in [prev, next, value_label]:
				_rows.add_child(n)
			_widgets[spec.id] = {"spec": spec, "widget": prev, "next": next, "value_label": value_label}
		"slider":
			var l := _text(spec.label)
			l.position = Vector3(left, y, 0.0)
			_rows.add_child(l)
			var value_w := 0.09
			var s := Slider3D.new(spec.min, spec.max, spec.step, spec.value, right_w - value_w - 0.03)
			s.position = Vector3(left + LABEL_W + (right_w - value_w) * 0.5, y, 0.0)
			var value_label := _text(spec.format % spec.value, 24, HORIZONTAL_ALIGNMENT_RIGHT)
			value_label.position = Vector3(WIDTH * 0.5, y, 0.0)
			s.value_changed.connect(func(v: float) -> void:
				spec.value = v
				value_label.text = spec.format % v
				control_changed.emit(spec.id, v))
			_rows.add_child(s)
			_rows.add_child(value_label)
			_widgets[spec.id] = {"spec": spec, "widget": s, "value_label": value_label}
	return y - ROW - GAP
