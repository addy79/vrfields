class_name ControlSpec
extends RefCounted
## Builders for control descriptions. Topics list their controls as plain
## dictionaries; the VR panel (ControlPanel3D) and the desktop HUD both render
## them and report changes as (id, value).


static func header(label: String) -> Dictionary:
	return {"type": "header", "id": "", "label": label}


static func button(id: String, label: String) -> Dictionary:
	return {"type": "button", "id": id, "label": label}


static func toggle(id: String, label: String, value: bool) -> Dictionary:
	return {"type": "toggle", "id": id, "label": label, "value": value}


static func choice(id: String, label: String, options: PackedStringArray, value: int) -> Dictionary:
	return {"type": "choice", "id": id, "label": label, "options": options, "value": value}


static func slider(id: String, label: String, min_value: float, max_value: float, step: float,
		value: float, format := "%.2f") -> Dictionary:
	return {"type": "slider", "id": id, "label": label, "min": min_value, "max": max_value,
			"step": step, "value": value, "format": format}
