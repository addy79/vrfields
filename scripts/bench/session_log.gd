class_name SessionLog
extends Node
## Interaction log for the user study: one CSV row per event
## (time_s, event, topic, detail). Written to user://sessions/, which is
## ~/.local/share/godot/app_userdata/VRFields/sessions on Linux and
## /sdcard/Android/data/com.example.vrfields/files/sessions on the Quest.
## Pass a participant code on the command line: -- --participant=P07

var participant := "anon"
var path := ""
var enabled := true

var _file: FileAccess
var _start_ms := 0
var _grab_started := {}


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--participant="):
			participant = arg.get_slice("=", 1).validate_filename()
		elif arg == "--no-log":
			enabled = false
	if not enabled:
		return
	DirAccess.make_dir_recursive_absolute("user://sessions")
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	path = "user://sessions/session_%s_%s.csv" % [participant, stamp]
	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		enabled = false
		return
	_start_ms = Time.get_ticks_msec()
	_file.store_line("time_s,event,topic,detail")
	log_event("start", "", "participant=%s; device=%s; gpu=%s" % [participant, OS.get_model_name(),
			RenderingServer.get_video_adapter_name()])


func log_event(event: String, topic: String, detail: String = "") -> void:
	if not enabled or _file == null:
		return
	var t := (Time.get_ticks_msec() - _start_ms) / 1000.0
	_file.store_line("%.3f,%s,%s,%s" % [t, event, _csv(topic), _csv(detail)])
	_file.flush()


func grab_started(topic: String, target: Node) -> void:
	_grab_started[target.get_instance_id()] = Time.get_ticks_msec()
	log_event("grab_start", topic, target.name)


func grab_ended(topic: String, target: Node) -> void:
	var start: int = _grab_started.get(target.get_instance_id(), Time.get_ticks_msec())
	_grab_started.erase(target.get_instance_id())
	log_event("grab_end", topic, "%s; held %.2f s" % [target.name, (Time.get_ticks_msec() - start) / 1000.0])


static func _csv(s: String) -> String:
	if s.contains(",") or s.contains("\"") or s.contains("\n"):
		return "\"" + s.replace("\"", "\"\"").replace("\n", " ") + "\""
	return s
