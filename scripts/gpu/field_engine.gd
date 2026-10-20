class_name FieldEngine
extends RefCounted
## Base class for the engines that turn user functions into data textures.
##
## Two interchangeable backends write the SAME texture layout, so the visual
## shaders cannot tell them apart:
##   GPU: a runtime-compiled compute shader writes RenderingDevice textures,
##        which the visual shaders sample directly (no CPU round-trip);
##   CPU: GDScript evaluates the same expressions (Godot Expression) point by
##        point and uploads an ImageTexture every update. This is the baseline
##        the GPU path is benchmarked against.
## Subclasses implement _gpu_source(), _gpu_resources(), _gpu_update() and _cpu_update().

signal compiled(error: String)

enum Backend { GPU, CPU }

## Seconds between asynchronous GPU stats read-backs (labels only).
const STATS_INTERVAL := 0.25

var backend := Backend.GPU
var program := GpuProgram.new()
## Time and user parameters available in every expression.
var t := 0.0
var param_a := 1.0
var param_b := 1.0
## Set when anything changed that needs the data recomputed.
var dirty := true
## Recompute every frame even when nothing changed (benchmarks).
var force_every_frame := false
## Wall-clock milliseconds the last CPU update took (0 on the GPU path).
var cpu_update_ms := 0.0
## Output name -> number of data points evaluated per update (for the stats overlay).
var workload := {}

var _cpu_textures := {}
var _gpu_built_for := -1
var _stats_timer := 0.0
var _label := "engine"


func _init(label: String) -> void:
	_label = label


func is_time_dependent() -> bool:
	return false


func set_backend(value: Backend) -> void:
	if value == Backend.GPU and not GpuProgram.is_supported():
		value = Backend.CPU
	if value != backend:
		backend = value
		dirty = true


func backend_name() -> String:
	return "GPU compute" if backend == Backend.GPU else "CPU (GDScript)"


## Rebuilds the compute shader after the functions changed. Returns quickly; the
## result arrives through `compiled` (GPU) or immediately (CPU).
func rebuild() -> void:
	dirty = true
	if GpuProgram.is_supported():
		program.build(_gpu_source(), _gpu_passes())
		_gpu_built_for = program.build_version
	else:
		compiled.emit.call_deferred("")


## Per-frame update. Returns true if the data was recomputed.
func update(delta: float) -> bool:
	if program.status == GpuProgram.Status.COMPILING:
		return false
	if _gpu_built_for >= 0 and program.status != GpuProgram.Status.COMPILING:
		var error := program.error if program.status == GpuProgram.Status.FAILED else ""
		_gpu_built_for = -1
		compiled.emit(error)
	program.tick()
	var recompute := dirty or force_every_frame or is_time_dependent()
	if backend == Backend.GPU and program.status == GpuProgram.Status.READY:
		_gpu_resources()
		program.timestamp("%s_begin" % _label)
		_gpu_update(recompute, delta)
		program.timestamp("%s_end" % _label)
		cpu_update_ms = 0.0
		_stats_timer -= delta
		if _stats_timer <= 0.0:
			_stats_timer = STATS_INTERVAL
			_gpu_read_stats()
	elif backend == Backend.CPU:
		var start := Time.get_ticks_usec()
		_cpu_update(recompute, delta)
		cpu_update_ms = (Time.get_ticks_usec() - start) / 1000.0
	dirty = false
	return recompute


## The texture a material should sample for `name` on the active backend.
func get_output(name: String) -> Texture:
	if backend == Backend.GPU:
		return program.get_texture(name)
	return _cpu_textures.get(name)


func free_gpu() -> void:
	program.free_all()


# --- Subclass hooks ---------------------------------------------------------------

func _gpu_source() -> String:
	return ""


func _gpu_passes() -> Array:
	return []


## Declare textures/buffers (cheap when unchanged).
func _gpu_resources() -> void:
	pass


func _gpu_update(_recompute: bool, _delta: float) -> void:
	pass


func _gpu_read_stats() -> void:
	pass


func _cpu_update(_recompute: bool, _delta: float) -> void:
	pass


# --- CPU texture helpers -------------------------------------------------------------

## Uploads RGBA float data (4 floats per texel) as a 2D texture.
func _cpu_texture_2d(name: String, width: int, height: int, data: PackedFloat32Array) -> void:
	var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, data.to_byte_array())
	var tex: ImageTexture = _cpu_textures.get(name)
	if tex and tex.get_width() == width and tex.get_height() == height:
		tex.update(image)
	else:
		_cpu_textures[name] = ImageTexture.create_from_image(image)


## Uploads RGBA float data as a size³ half-float 3D texture (slice-major: z, then y, then x).
func _cpu_texture_3d(name: String, size: int, data: PackedFloat32Array) -> void:
	var slices: Array[Image] = []
	var slice_floats := size * size * 4
	for z in size:
		var slice := data.slice(z * slice_floats, (z + 1) * slice_floats)
		var image := Image.create_from_data(size, size, false, Image.FORMAT_RGBAF, slice.to_byte_array())
		image.convert(Image.FORMAT_RGBAH)
		slices.append(image)
	var tex: ImageTexture3D = _cpu_textures.get(name)
	if tex and tex.get_width() == size:
		tex.update(slices)
	else:
		tex = ImageTexture3D.new()
		tex.create(Image.FORMAT_RGBAH, size, size, size, false, slices)
		_cpu_textures[name] = tex


static func groups(count: int, local_size: int) -> int:
	return int(ceil(float(count) / local_size))
