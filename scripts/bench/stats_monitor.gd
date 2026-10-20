class_name StatsMonitor
extends Node
## Frame-time statistics for the overlay and the benchmarks.
## Per frame it records:
##   frame_ms    wall-clock time between frames (what the user experiences)
##   gpu_ms      GPU time of the whole viewport render (Godot's measurement)
##   compute_ms  GPU time between our compute timestamps ("<label>_begin/_end")
##   update_ms   CPU time the engines spent this frame (the CPU baseline's cost)
## Timestamps and GPU times arrive with a delay of a frame or two; that does not
## matter for averages over hundreds of frames.

const WINDOW := 240

## Frame budget for the target refresh rate (90 Hz -> 11.1 ms).
var target_hz := 90.0
var engines_provider: Callable

var _frame := PackedFloat32Array()
var _gpu := PackedFloat32Array()
var _compute := PackedFloat32Array()
var _update := PackedFloat32Array()
var _recording := false
var _record := {}
var _viewport_rid: RID
var _rd: RenderingDevice
var _last_usec := 0


func _ready() -> void:
	_viewport_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)
	_rd = RenderingServer.get_rendering_device()
	process_priority = -100


func _process(delta: float) -> void:
	# Wall clock, not `delta`: Godot caps delta at max_physics_steps_per_frame
	# physics ticks (8 / 90 Hz = 89 ms), which would hide slow CPU frames.
	var now := Time.get_ticks_usec()
	var frame_ms := delta * 1000.0 if _last_usec == 0 else (now - _last_usec) / 1000.0
	_last_usec = now
	var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)
	var compute_ms := _compute_time_ms()
	var update_ms := 0.0
	if engines_provider.is_valid():
		for e: FieldEngine in engines_provider.call():
			update_ms += e.cpu_update_ms
	_push(_frame, frame_ms)
	_push(_gpu, gpu_ms)
	_push(_compute, compute_ms)
	_push(_update, update_ms)
	if _recording:
		_record.frame.append(frame_ms)
		_record.gpu.append(gpu_ms)
		_record.compute.append(compute_ms)
		_record.update.append(update_ms)


func _push(buffer: PackedFloat32Array, value: float) -> void:
	buffer.append(value)
	if buffer.size() > WINDOW:
		buffer.remove_at(0)


## Sum over all "<x>_begin" / "<x>_end" timestamp pairs of the last captured frame.
func _compute_time_ms() -> float:
	if _rd == null:
		return 0.0
	var count := _rd.get_captured_timestamps_count()
	var begins := {}
	var total := 0.0
	for i in count:
		var name := _rd.get_captured_timestamp_name(i)
		var t := _rd.get_captured_timestamp_gpu_time(i)
		if name.ends_with("_begin"):
			begins[name.trim_suffix("_begin")] = t
		elif name.ends_with("_end"):
			var key := name.trim_suffix("_end")
			if begins.has(key):
				total += float(t - begins[key])
	# GPU timestamps are in nanoseconds.
	return total / 1e6


func start_recording() -> void:
	_record = {"frame": PackedFloat32Array(), "gpu": PackedFloat32Array(),
			"compute": PackedFloat32Array(), "update": PackedFloat32Array()}
	_recording = true


func stop_recording() -> Dictionary:
	_recording = false
	return summarize(_record)


func recorded_frames() -> int:
	return _record.get("frame", PackedFloat32Array()).size() if _recording else 0


func live() -> Dictionary:
	return summarize({"frame": _frame, "gpu": _gpu, "compute": _compute, "update": _update})


func summarize(data: Dictionary) -> Dictionary:
	var frame: PackedFloat32Array = data.get("frame", PackedFloat32Array())
	if frame.is_empty():
		return {"frames": 0, "fps": 0.0, "mean_ms": 0.0, "p50_ms": 0.0, "p95_ms": 0.0, "p99_ms": 0.0,
				"max_ms": 0.0, "over_budget_pct": 0.0, "gpu_ms": 0.0, "compute_ms": 0.0, "update_ms": 0.0}
	var sorted := frame.duplicate()
	sorted.sort()
	var budget := 1000.0 / target_hz
	var over := 0
	for v in frame:
		# 5 % tolerance: vsync jitter around the budget is not a dropped frame.
		if v > budget * 1.05:
			over += 1
	var mean := _mean(frame)
	return {
		"frames": frame.size(),
		"fps": 1000.0 / maxf(mean, 1e-6),
		"mean_ms": mean,
		"p50_ms": _pct(sorted, 0.50),
		"p95_ms": _pct(sorted, 0.95),
		"p99_ms": _pct(sorted, 0.99),
		"max_ms": sorted[sorted.size() - 1],
		"over_budget_pct": 100.0 * over / frame.size(),
		"gpu_ms": _mean(data.gpu),
		"compute_ms": _mean(data.compute),
		"update_ms": _mean(data.update),
	}


static func _mean(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


static func _pct(sorted: PackedFloat32Array, q: float) -> float:
	var i := clampi(int(ceil(q * sorted.size())) - 1, 0, sorted.size() - 1)
	return sorted[i]
