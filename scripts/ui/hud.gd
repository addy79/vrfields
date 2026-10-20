class_name Hud
extends CanvasLayer
## Desktop HUD: topic bar, live performance stats, the global and topic controls
## (built from ControlSpec lists), the function editor, a readout and toasts.

signal topic_requested(index: int)
signal control_changed(id: String, value: Variant)
signal function_submitted(text: String)

var _root := Control.new()
var _crosshair := Crosshair.new()
var _stats := Label.new()
var _help := Label.new()
var _readout := Label.new()
var _toast := Label.new()
var _global_box := VBoxContainer.new()
var _topic_box := VBoxContainer.new()
var _left := PanelContainer.new()
var _right := PanelContainer.new()
var _bottom := PanelContainer.new()
var _function_label := Label.new()
var _function_edit := LineEdit.new()
var _function_help := Label.new()
var _function_status := Label.new()
var _topic_buttons: Array[Button] = []
var _widgets := {}
var _toast_tween: Tween


class Crosshair:
	extends Control
	var active := false:
		set(value):
			if value != active:
				active = value
				queue_redraw()

	func _draw() -> void:
		var c := size * 0.5
		var color := Color(0.4, 1.0, 0.5) if active else Color(1, 1, 1, 0.8)
		for d: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
			draw_line(c + d * 4.0, c + d * 13.0, Color(0, 0, 0, 0.6), 4.0)
			draw_line(c + d * 4.0, c + d * 13.0, color, 2.0)


func setup(titles: PackedStringArray) -> void:
	var theme := Theme.new()
	theme.default_font = MeshUtil.math_font()
	theme.default_font_size = 14
	_root.theme = theme
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_crosshair)

	var bar := HBoxContainer.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 8)
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bar.add_theme_constant_override("separation", 6)
	_root.add_child(bar)
	for i in titles.size():
		var b := Button.new()
		b.text = "%d  %s" % [i + 1, titles[i]]
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(topic_requested.emit.bind(i))
		bar.add_child(b)
		_topic_buttons.append(b)

	# Left: stats + session controls + help.
	_style(_left)
	_left.position = Vector2(8, 48)
	_left.custom_minimum_size = Vector2(250, 0)
	_root.add_child(_left)
	var left_box := VBoxContainer.new()
	_left.add_child(left_box)
	_stats.add_theme_font_size_override("font_size", 12)
	left_box.add_child(_stats)
	_help.add_theme_font_size_override("font_size", 12)
	_help.modulate = Color(0.8, 0.88, 1.0)
	_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_help.custom_minimum_size = Vector2(240, 0)
	left_box.add_child(_help)
	_help.text = _controls_text()

	# Right: topic controls + readout, scrollable.
	_style(_right)
	_right.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_right.offset_left = -330
	_right.offset_right = -8
	_right.offset_top = 48
	_right.offset_bottom = -8
	_root.add_child(_right)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_right.add_child(scroll)
	var right_box := VBoxContainer.new()
	right_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(right_box)
	right_box.add_child(_global_box)
	right_box.add_child(HSeparator.new())
	right_box.add_child(_topic_box)
	right_box.add_child(HSeparator.new())
	_readout.add_theme_font_size_override("font_size", 13)
	_readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_readout.custom_minimum_size = Vector2(300, 0)
	right_box.add_child(_readout)

	# Bottom: function editor.
	_style(_bottom)
	_bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_bottom.offset_left = 8
	_bottom.offset_right = -338
	_bottom.offset_top = -112
	_bottom.offset_bottom = -8
	_root.add_child(_bottom)
	var bottom_box := VBoxContainer.new()
	_bottom.add_child(bottom_box)
	var row := HBoxContainer.new()
	bottom_box.add_child(row)
	_function_label.add_theme_font_size_override("font_size", 16)
	row.add_child(_function_label)
	_function_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_function_edit.add_theme_font_size_override("font_size", 16)
	_function_edit.text_submitted.connect(_on_submit)
	row.add_child(_function_edit)
	var plot := Button.new()
	plot.text = "Plot"
	plot.focus_mode = Control.FOCUS_NONE
	plot.pressed.connect(func() -> void: _on_submit(_function_edit.text))
	row.add_child(plot)
	_function_help.add_theme_font_size_override("font_size", 12)
	_function_help.modulate = Color(0.75, 0.8, 0.9)
	bottom_box.add_child(_function_help)
	_function_status.add_theme_font_size_override("font_size", 13)
	bottom_box.add_child(_function_status)

	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 130)
	_toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast.custom_minimum_size = Vector2(560, 0)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_toast.add_theme_font_size_override("font_size", 20)
	_toast.add_theme_constant_override("outline_size", 6)
	_toast.add_theme_color_override("font_outline_color", Color.BLACK)
	_toast.modulate.a = 0.0
	_root.add_child(_toast)


func _style(panel: PanelContainer) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.08, 0.78)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)


func set_topic(index: int) -> void:
	for i in _topic_buttons.size():
		_topic_buttons[i].set_pressed_no_signal(i == index)


func build_global(specs: Array) -> void:
	_build(_global_box, specs)


func build_topic(specs: Array) -> void:
	_build(_topic_box, specs)


func set_value(id: String, value: Variant) -> void:
	var w: Variant = _widgets.get(id)
	if w == null or not is_instance_valid(w.control):
		return
	var spec: Dictionary = w.spec
	match spec.type:
		"toggle":
			(w.control as CheckBox).set_pressed_no_signal(value)
		"choice":
			(w.control as OptionButton).select(value)
		"slider":
			(w.control as HSlider).set_value_no_signal(value)
			(w.value_label as Label).text = spec.format % value


func _build(box: VBoxContainer, specs: Array) -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()
	for spec: Dictionary in specs:
		match spec.type:
			"header":
				var l := Label.new()
				l.text = spec.label
				l.add_theme_font_size_override("font_size", 15)
				l.modulate = Color(0.6, 0.8, 1.0)
				box.add_child(l)
			"button":
				var b := Button.new()
				b.text = spec.label
				b.focus_mode = Control.FOCUS_NONE
				b.pressed.connect(func() -> void: control_changed.emit(spec.id, true))
				box.add_child(b)
				_widgets[spec.id] = {"spec": spec, "control": b}
			"toggle":
				var c := CheckBox.new()
				c.text = spec.label
				c.button_pressed = spec.value
				c.focus_mode = Control.FOCUS_NONE
				c.toggled.connect(func(on: bool) -> void: control_changed.emit(spec.id, on))
				box.add_child(c)
				_widgets[spec.id] = {"spec": spec, "control": c}
			"choice":
				var row := HBoxContainer.new()
				var l := Label.new()
				l.text = spec.label
				l.custom_minimum_size = Vector2(92, 0)
				row.add_child(l)
				var o := OptionButton.new()
				o.focus_mode = Control.FOCUS_NONE
				o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				o.clip_text = true
				for option: String in spec.options:
					o.add_item(option)
				o.select(spec.value)
				o.item_selected.connect(func(i: int) -> void: control_changed.emit(spec.id, i))
				row.add_child(o)
				box.add_child(row)
				_widgets[spec.id] = {"spec": spec, "control": o}
			"slider":
				var row := HBoxContainer.new()
				var l := Label.new()
				l.text = spec.label
				l.custom_minimum_size = Vector2(92, 0)
				row.add_child(l)
				var s := HSlider.new()
				s.min_value = spec.min
				s.max_value = spec.max
				s.step = spec.step
				s.value = spec.value
				s.focus_mode = Control.FOCUS_NONE
				s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				var v := Label.new()
				v.text = spec.format % spec.value
				v.custom_minimum_size = Vector2(50, 0)
				v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				s.value_changed.connect(func(x: float) -> void:
					v.text = spec.format % x
					control_changed.emit(spec.id, x))
				row.add_child(s)
				row.add_child(v)
				box.add_child(row)
				_widgets[spec.id] = {"spec": spec, "control": s, "value_label": v}


func set_function_spec(spec: Dictionary) -> void:
	_bottom.visible = not spec.is_empty()
	if spec.is_empty():
		return
	_function_label.text = spec.label
	_function_edit.text = spec.text
	_function_help.text = spec.help
	_function_status.text = ""


func set_function_text(text: String) -> void:
	_function_edit.text = text


func show_function_result(error: String) -> void:
	if error.is_empty():
		_function_status.text = "✓ Plotted"
		_function_status.modulate = Color(0.5, 1.0, 0.6)
	else:
		_function_status.text = "✗ " + error
		_function_status.modulate = Color(1.0, 0.5, 0.45)


func focus_function() -> void:
	_function_edit.grab_focus()
	_function_edit.caret_column = _function_edit.text.length()


func is_typing() -> bool:
	return _function_edit.has_focus()


func set_stats(text: String) -> void:
	_stats.text = text


func set_readout(text: String) -> void:
	_readout.text = text


func set_crosshair(visible_now: bool, active: bool) -> void:
	_crosshair.visible = visible_now
	_crosshair.active = active


func set_panels_visible(value: bool) -> void:
	for p: Control in [_left, _right, _bottom]:
		p.visible = value


## Width in pixels the right column takes (0 when hidden).
func right_width() -> float:
	return 338.0 if _right.visible else 0.0


func panels_visible() -> bool:
	return _left.visible


func toggle_help() -> void:
	_help.visible = not _help.visible


func toast(message: String, seconds := 3.0) -> void:
	_toast.text = message
	if _toast_tween:
		_toast_tween.kill()
	_toast.modulate.a = 1.0
	_toast_tween = create_tween()
	_toast_tween.tween_interval(seconds)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.6)


func _on_submit(text: String) -> void:
	_function_edit.release_focus()
	function_submitted.emit(text)


func _controls_text() -> String:
	var k := {}
	for a in ["move_forward", "move_left", "move_back", "move_right", "move_down", "move_up",
			"topic_action", "toggle_backend", "toggle_help", "toggle_hud", "toggle_xr", "reset_view", "screenshot"]:
		k[a] = InputSetup.key_label(a)
	return "\n".join(PackedStringArray([
		"{move_forward}{move_left}{move_back}{move_right} fly, {move_down}/{move_up} down/up, hold right mouse to look".format(k),
		"Left click: grab probes and handles",
		"Arrows / wheel / {topic_action}: topic controls".format(k),
		"1-5 topics   {toggle_backend} GPU↔CPU   {reset_view} reset view".format(k),
		"{toggle_hud} hide panels   {toggle_help} help   {screenshot} screenshot".format(k),
	]))
