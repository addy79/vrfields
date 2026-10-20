class_name Benchmark
extends Node
## Measures every topic × backend (GPU compute / CPU baseline) × resolution level
## with the data recomputed EVERY frame (force_every_frame), so both backends do
## the same work per frame. Writes a CSV (one row per configuration) to
## user://benchmarks/ and, when run from the project folder, to res://benchmarks/.
##
## Run:  godot --path . -- --benchmark          (full sweep, then quit)
##       godot --path . -- --benchmark-quick    (fewer levels, shorter)
## or press "Run benchmark" in the app (desktop panel or VR panel).

signal finished(csv_path: String)

const CSV_HEADER := "timestamp,device,gpu,renderer,xr,topic,backend,quality,workload,points_per_frame,frames,fps,mean_ms,p50_ms,p95_ms,p99_ms,max_ms,over_budget_pct,gpu_frame_ms,compute_gpu_ms,cpu_update_ms"
## A CPU level slower than this (mean frame time) ends that topic's CPU sweep:
## higher levels would only be slower.
const CPU_GIVE_UP_MS := 1500.0

var main: Node
var quick := false
var quit_when_done := false
var running := false
var rows: Array[Dictionary] = []

var _lines := PackedStringArray()


func run() -> void:
	if running:
		return
	running = true
	rows.clear()
	_lines = PackedStringArray([CSV_HEADER])
	var warm := 0.5 if quick else 1.0
	var measure := 1.5 if quick else 3.0
	var levels := [0, 1, 2] if quick else [0, 1, 2, 3]
	var vsync := DisplayServer.window_get_vsync_mode()
	if not main.xr_active:
		# Measure real frame cost, not the monitor's refresh rate.
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var original_topic: int = main.current_index
	var original_backend: int = main.backend
	var original_quality: int = main.quality
	for topic_index in main.TOPICS.size():
		main.load_topic(topic_index)
		for backend in [FieldEngine.Backend.GPU, FieldEngine.Backend.CPU]:
			if backend == FieldEngine.Backend.GPU and not GpuProgram.is_supported():
				continue
			for level: int in levels:
				var row: Dictionary = await _measure(topic_index, backend, level, warm, measure)
				if backend == FieldEngine.Backend.CPU and row.mean_ms > CPU_GIVE_UP_MS:
					break
	for e: FieldEngine in main.current_engines():
		e.force_every_frame = false
	DisplayServer.window_set_vsync_mode(vsync)
	main.set_backend(original_backend)
	main.set_quality(original_quality)
	main.load_topic(original_topic)
	var path := _write_csv()
	running = false
	finished.emit(path)
	if quit_when_done:
		get_tree().quit()


func _measure(topic_index: int, backend: int, level: int, warm: float, measure: float) -> Dictionary:
	main.set_backend(backend)
	main.set_quality(level)
	for e: FieldEngine in main.current_engines():
		e.force_every_frame = true
	main.hud.toast("Benchmark: %s, %s, %s" % [main.TOPICS[topic_index].title,
			"GPU" if backend == FieldEngine.Backend.GPU else "CPU", Topic.QUALITY_NAMES[level]], 2.0)
	# Wait for the shader compile and warm up (at least 3 frames).
	await _frames_or_time(3, warm)
	main.stats.start_recording()
	# At least 5 frames (slow CPU levels), at most `measure` seconds (fast ones).
	var start := Time.get_ticks_msec()
	while main.stats.recorded_frames() < 5 or (Time.get_ticks_msec() - start) < measure * 1000.0:
		await get_tree().process_frame
		if main.stats.recorded_frames() >= 5 and Time.get_ticks_msec() - start > 30000:
			break
	var s: Dictionary = main.stats.stop_recording()
	var work: Dictionary = main.current_topic.workload()
	var points := 0
	var parts := PackedStringArray()
	for k: String in work:
		points += int(work[k])
		parts.append("%s=%d" % [k, work[k]])
	var row := {
		"topic": main.TOPICS[topic_index].title,
		"backend": "GPU" if backend == FieldEngine.Backend.GPU else "CPU",
		"quality": Topic.QUALITY_NAMES[level],
		"workload": "; ".join(parts),
		"points": points,
	}
	row.merge(s)
	rows.append(row)
	_lines.append(",".join(PackedStringArray([
		Time.get_datetime_string_from_system(), _q(OS.get_model_name()), _q(RenderingServer.get_video_adapter_name()),
		RenderingServer.get_current_rendering_method(), str(main.xr_active), _q(row.topic), row.backend,
		row.quality, _q(row.workload), str(points), str(s.frames), "%.2f" % s.fps, "%.3f" % s.mean_ms,
		"%.3f" % s.p50_ms, "%.3f" % s.p95_ms, "%.3f" % s.p99_ms, "%.3f" % s.max_ms,
		"%.1f" % s.over_budget_pct, "%.3f" % s.gpu_ms, "%.3f" % s.compute_ms, "%.3f" % s.update_ms])))
	print("[BENCH] %-22s %-3s %-6s %8.2f ms  p99 %8.2f  fps %7.1f  compute %.3f ms  cpu-update %.2f ms  (%s)" % [
			row.topic, row.backend, row.quality, s.mean_ms, s.p99_ms, s.fps, s.compute_ms, s.update_ms, row.workload])
	return row


func _frames_or_time(frames: int, seconds: float) -> void:
	var start := Time.get_ticks_msec()
	var n := 0
	while n < frames or (Time.get_ticks_msec() - start) < seconds * 1000.0:
		await get_tree().process_frame
		n += 1


func _write_csv() -> String:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var name := "benchmark_%s_%s.csv" % ["quest" if OS.get_name() == "Android" else "desktop", stamp]
	DirAccess.make_dir_recursive_absolute("user://benchmarks")
	var user_path := "user://benchmarks/" + name
	_save(user_path)
	if not OS.has_feature("template"):
		_save("res://benchmarks/" + name)
		return ProjectSettings.globalize_path("res://benchmarks/" + name)
	return ProjectSettings.globalize_path(user_path)


func _save(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


static func _q(s: String) -> String:
	return "\"" + s.replace("\"", "'") + "\""
