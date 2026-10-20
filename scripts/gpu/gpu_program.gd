class_name GpuProgram
extends RefCounted
## One runtime-compiled compute shader with several passes, plus the GPU
## textures and buffers it writes. Everything runs on Godot's main
## RenderingDevice, so the output textures are sampled directly by the
## visual shaders (Texture2DRD / Texture3DRD) with no CPU round-trip.
##
## All RenderingDevice work is queued with RenderingServer.call_on_render_thread
## and runs in submission order. The main thread only reads `status`, `error`
## and the texture RIDs, and wraps the RIDs once `resource_version` changes.

enum Status { EMPTY, COMPILING, READY, FAILED }

const TEX_2D := 0
const TEX_3D := 1

var status := Status.EMPTY
var error := ""
## Increases when textures are (re)created; consumers then re-wrap the RIDs.
var resource_version := 0
## Increases after each successful compile.
var build_version := 0

var _rd: RenderingDevice
var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _pass_bindings: Array = []        # pass -> Array of resource names
var _uniform_sets: Array[RID] = []
## name -> {"rid", "binding", "kind": "image"|"buffer", "type", "size", "format", "bytes"}
var _resources := {}
var _wrappers := {}                   # name -> Texture2DRD / Texture3DRD
## Replaced resources still referenced by materials: [rid, frames left].
var _graveyard: Array = []

const RETIRE_FRAMES := 4


func _init() -> void:
	_rd = RenderingServer.get_rendering_device()


static func is_supported() -> bool:
	return RenderingServer.get_rendering_device() != null


## Compiles `source` once per pass. `passes`: [{"define": "PASS_EVAL",
## "bindings": ["field", "stats"]}, ...]; each pass sees "#define <define>".
func build(source: String, passes: Array) -> void:
	status = Status.COMPILING
	error = ""
	RenderingServer.call_on_render_thread(_rt_build.bind(source, passes.duplicate(true)))


## Declares a storage image. Recreated when size or format changes.
func texture(name: String, binding: int, type: int, size: Vector3i,
		format := RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT) -> void:
	RenderingServer.call_on_render_thread(_rt_texture.bind(name, binding, type, size, format))


## Declares a storage buffer of `bytes` bytes (zero-filled on creation).
func buffer(name: String, binding: int, bytes: int) -> void:
	RenderingServer.call_on_render_thread(_rt_buffer.bind(name, binding, bytes))


func clear_buffer(name: String) -> void:
	RenderingServer.call_on_render_thread(_rt_clear_buffer.bind(name))


func upload_buffer(name: String, data: PackedByteArray) -> void:
	RenderingServer.call_on_render_thread(_rt_upload_buffer.bind(name, data))


## Queues one dispatch of `pass_index` with `groups` work groups.
func dispatch(pass_index: int, groups: Vector3i, push: PackedByteArray) -> void:
	RenderingServer.call_on_render_thread(_rt_dispatch.bind(pass_index, groups, push))


## Records a GPU timestamp (read back a frame later by GpuTimer).
func timestamp(label: String) -> void:
	RenderingServer.call_on_render_thread(func() -> void: _rd.capture_timestamp(label))


## A Texture2DRD/Texture3DRD for a declared image, kept in sync with its RID.
## Returns null until the texture exists.
func get_texture(name: String) -> Texture:
	if not _resources.has(name) or not _resources[name].rid.is_valid():
		return null
	var res: Dictionary = _resources[name]
	var wrapper: Texture = _wrappers.get(name)
	if wrapper == null:
		wrapper = Texture2DRD.new() if res.type == TEX_2D else Texture3DRD.new()
		_wrappers[name] = wrapper
	if wrapper.texture_rd_rid != res.rid:
		wrapper.texture_rd_rid = res.rid
	return wrapper


## Reads a texture or buffer back to the CPU (slow, for tests): calls
## `callback(PackedByteArray)` on the main thread.
func read_back(name: String, callback: Callable) -> void:
	RenderingServer.call_on_render_thread(_rt_read_back.bind(name, callback))


## Call once per frame: frees replaced resources after materials let go of them.
func tick() -> void:
	if not _graveyard.is_empty():
		RenderingServer.call_on_render_thread(_rt_tick)


## Frees everything a moment later, once the materials sampling these
## textures (freed with their topic at the end of this frame) are gone.
func free_all() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		RenderingServer.call_on_render_thread(_rt_free_all)
		return
	tree.create_timer(0.25).timeout.connect(func() -> void:
		RenderingServer.call_on_render_thread(_rt_free_all))


# --- Render thread ---------------------------------------------------------------

func _rt_build(source: String, passes: Array) -> void:
	_rt_free_pipelines()
	_pass_bindings.clear()
	for p: Dictionary in passes:
		var shader_source := RDShaderSource.new()
		shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
		shader_source.source_compute = source.replace("#version 450",
				"#version 450\n#define %s" % p.define)
		var spirv := _rd.shader_compile_spirv_from_source(shader_source)
		if not spirv.compile_error_compute.is_empty():
			_rt_free_pipelines()
			error = _first_error_line(spirv.compile_error_compute)
			status = Status.FAILED
			push_warning("GpuProgram %s: %s" % [p.define, spirv.compile_error_compute])
			return
		var shader := _rd.shader_create_from_spirv(spirv, p.define)
		if not shader.is_valid():
			_rt_free_pipelines()
			error = "shader_create_from_spirv failed"
			status = Status.FAILED
			return
		_shaders.append(shader)
		_pipelines.append(_rd.compute_pipeline_create(shader))
		_pass_bindings.append(p.bindings)
		_uniform_sets.append(RID())
	build_version += 1
	status = Status.READY


func _rt_texture(name: String, binding: int, type: int, size: Vector3i, format: int) -> void:
	var old: Dictionary = _resources.get(name, {})
	if not old.is_empty() and old.size == size and old.format == format and old.rid.is_valid():
		return
	if not old.is_empty() and old.rid.is_valid():
		_graveyard.append([old.rid, RETIRE_FRAMES])
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D if type == TEX_2D else RenderingDevice.TEXTURE_TYPE_3D
	fmt.width = size.x
	fmt.height = size.y
	fmt.depth = size.z if type == TEX_3D else 1
	fmt.format = format
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var rid := _rd.texture_create(fmt, RDTextureView.new())
	_rd.texture_clear(rid, Color(0, 0, 0, 0), 0, 1, 0, 1)
	_resources[name] = {"rid": rid, "binding": binding, "kind": "image", "type": type,
			"size": size, "format": format}
	_invalidate_sets()
	resource_version += 1


func _rt_buffer(name: String, binding: int, bytes: int) -> void:
	var old: Dictionary = _resources.get(name, {})
	if not old.is_empty() and old.bytes == bytes and old.rid.is_valid():
		return
	if not old.is_empty() and old.rid.is_valid():
		_graveyard.append([old.rid, RETIRE_FRAMES])
	var data := PackedByteArray()
	data.resize(bytes)
	var rid := _rd.storage_buffer_create(bytes, data)
	_resources[name] = {"rid": rid, "binding": binding, "kind": "buffer", "type": -1, "bytes": bytes}
	_invalidate_sets()
	resource_version += 1


func _rt_clear_buffer(name: String) -> void:
	var res: Dictionary = _resources.get(name, {})
	if not res.is_empty():
		_rd.buffer_clear(res.rid, 0, res.bytes)


func _rt_upload_buffer(name: String, data: PackedByteArray) -> void:
	var res: Dictionary = _resources.get(name, {})
	if not res.is_empty():
		_rd.buffer_update(res.rid, 0, mini(data.size(), res.bytes), data)


func _rt_dispatch(pass_index: int, groups: Vector3i, push: PackedByteArray) -> void:
	if status != Status.READY or pass_index >= _pipelines.size():
		return
	var uniform_set := _uniform_sets[pass_index]
	if not uniform_set.is_valid() or not _rd.uniform_set_is_valid(uniform_set):
		uniform_set = _rt_make_set(pass_index)
		if not uniform_set.is_valid():
			return
		_uniform_sets[pass_index] = uniform_set
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[pass_index])
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_set_push_constant(list, push, push.size())
	_rd.compute_list_dispatch(list, maxi(groups.x, 1), maxi(groups.y, 1), maxi(groups.z, 1))
	_rd.compute_list_end()


func _rt_make_set(pass_index: int) -> RID:
	var uniforms: Array[RDUniform] = []
	for name: String in _pass_bindings[pass_index]:
		if not _resources.has(name):
			return RID()
		var res: Dictionary = _resources[name]
		var uniform := RDUniform.new()
		uniform.binding = res.binding
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE if res.kind == "image" \
				else RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.add_id(res.rid)
		uniforms.append(uniform)
	return _rd.uniform_set_create(uniforms, _shaders[pass_index], 0)


func _rt_read_back(name: String, callback: Callable) -> void:
	var res: Dictionary = _resources.get(name, {})
	var data := PackedByteArray()
	if not res.is_empty():
		data = _rd.texture_get_data(res.rid, 0) if res.kind == "image" else _rd.buffer_get_data(res.rid)
	callback.call_deferred(data)


func _rt_tick() -> void:
	for i in range(_graveyard.size() - 1, -1, -1):
		_graveyard[i][1] -= 1
		if _graveyard[i][1] <= 0:
			if _graveyard[i][0].is_valid():
				_rd.free_rid(_graveyard[i][0])
			_graveyard.remove_at(i)


func _invalidate_sets() -> void:
	for i in _uniform_sets.size():
		_uniform_sets[i] = RID()


func _rt_free_pipelines() -> void:
	# Freeing a shader also frees its pipelines and uniform sets.
	for shader in _shaders:
		if shader.is_valid():
			_rd.free_rid(shader)
	_shaders.clear()
	_pipelines.clear()
	_uniform_sets.clear()


func _rt_free_all() -> void:
	_rt_free_pipelines()
	for entry: Array in _graveyard:
		if entry[0].is_valid():
			_rd.free_rid(entry[0])
	_graveyard.clear()
	for name: String in _resources:
		var rid: RID = _resources[name].rid
		if rid.is_valid():
			_rd.free_rid(rid)
	_resources.clear()


static func _first_error_line(text: String) -> String:
	for line in text.split("\n"):
		if "ERROR" in line or "error" in line:
			return line.strip_edges().substr(0, 160)
	return text.strip_edges().substr(0, 160)
