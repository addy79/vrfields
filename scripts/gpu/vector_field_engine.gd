class_name VectorFieldEngine
extends FieldEngine
## F(x, y, z) on the cube [-E, E]³ (math coordinates, z up). Outputs:
##   "field"     N × N² RGBA32F: F at grid point (i, j, k) is texel (i, j + N k), w = |F|
##   "stats"     1 × 1  RGBA32F: (max |F| on the grid, max |div F|, max |curl F|, 0)
##   "particles" 256 × 2R RGBA32F: rows 0..R-1 (position, age), rows R..2R-1 (F, |F|/max)
##   "volume"    M³ RGBA16F 3D (half floats: linear filtering works on every GPU): (div F, curl F) on an M³ grid
##   "lines"     (2L+1) × S RGBA32F: field line through seed s, texel (L + j, s) = (point, |F|/max)
## div and curl use central differences of the function itself (step H), so
## they are as exact as float precision allows, not limited by the grid.

const VARIABLES := ["x", "y", "z", "t", "a", "b"]
const PARTICLE_ROW := 256
## Central-difference step for div/curl, relative to the domain size.
const H_REL := 1e-3

var extent := 2.0
var grid_n := 12
var volume_m := 32
var particle_count := 4096
var line_seeds := 8
var line_steps := 96
var line_step_len := 0.04
var arrows_enabled := true
var volume_enabled := false
var particles_enabled := true
var lines_enabled := false
## Fastest particle speed in math units per second.
var flow_speed := 1.2
var particle_life := 5.0
## Particles respawn near this point (math coords) when emitter_radius > 0.
var emitter := Vector3.ZERO
var emitter_radius := 0.0
var emitter_fraction := 0.35
## Field-line seed points (math coordinates).
var seeds := PackedVector3Array()

var exprs: Array[MathExpr] = []
var text := ""
## Latest stats (GPU: read back asynchronously; CPU: computed directly).
var max_magnitude := 1.0
var max_divergence := 0.0
var max_curl := 0.0

var _frame := 0
var _seeds_dirty := true
var _args := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
var _cpu_particles := PackedFloat32Array()   # 8 floats per particle: pos, age, F, |F|/max
var _cpu_particle_count := -1


func _init() -> void:
	super("vf")


static func compile_text(source: String) -> Dictionary:
	return MathExpr.compile_tuple(source, PackedStringArray(VARIABLES), 3)


## Sets the field from typed text. Returns "" or an error message.
func set_field(source: String) -> String:
	var result := compile_text(source)
	if not result.error.is_empty():
		return result.error
	exprs.assign(result.exprs)
	text = source.strip_edges()
	rebuild()
	return ""


func is_time_dependent() -> bool:
	for e in exprs:
		if e.uses("t"):
			return true
	return false


func set_seeds(points: PackedVector3Array) -> void:
	seeds = points
	_seeds_dirty = true


func particle_rows() -> int:
	return int(ceil(float(particle_count) / PARTICLE_ROW))


func grid_point(i: int, j: int, k: int) -> Vector3:
	var s := 2.0 * extent / float(grid_n - 1)
	return Vector3(-extent + s * i, -extent + s * j, -extent + s * k)


# --- CPU evaluation (also used by probes in both modes) ------------------------------

## F at a math-space point; non-finite components count as 0 (like the GPU's fin()).
func field(p: Vector3) -> Vector3:
	_args[0] = p.x
	_args[1] = p.y
	_args[2] = p.z
	_args[3] = t
	_args[4] = param_a
	_args[5] = param_b
	var v := Vector3(exprs[0].evaluate(_args), exprs[1].evaluate(_args), exprs[2].evaluate(_args))
	for i in 3:
		if not is_finite(v[i]):
			v[i] = 0.0
	return v


func diff_step() -> float:
	return H_REL * maxf(extent, 1.0)


## div F and curl F by central differences: [div, curl].
func div_curl(p: Vector3) -> Array:
	var h := diff_step()
	var dx := (field(p + Vector3(h, 0, 0)) - field(p - Vector3(h, 0, 0))) / (2.0 * h)
	var dy := (field(p + Vector3(0, h, 0)) - field(p - Vector3(0, h, 0))) / (2.0 * h)
	var dz := (field(p + Vector3(0, 0, h)) - field(p - Vector3(0, 0, h))) / (2.0 * h)
	return [dx.x + dy.y + dz.z, Vector3(dy.z - dz.y, dz.x - dx.z, dx.y - dy.x)]


func divergence(p: Vector3) -> float:
	return div_curl(p)[0]


func curl(p: Vector3) -> Vector3:
	return div_curl(p)[1]


# --- GPU ---------------------------------------------------------------------------------

func _gpu_source() -> String:
	var args := PackedStringArray(["x", "y", "z"])
	return Glsl.HEADER + Glsl.vec3_function("Fu", args, exprs) + KERNELS


func _gpu_passes() -> Array:
	return [
		{"define": "PASS_GRID", "bindings": ["field", "stats_buf"]},
		{"define": "PASS_VOLUME", "bindings": ["volume", "stats_buf"]},
		{"define": "PASS_STATS", "bindings": ["stats_buf", "stats"]},
		{"define": "PASS_PARTICLES", "bindings": ["stats_buf", "particle_buf", "particles"]},
		{"define": "PASS_LINES", "bindings": ["stats_buf", "seed_buf", "lines"]},
	]


func _gpu_resources() -> void:
	program.texture("field", 0, GpuProgram.TEX_2D, Vector3i(grid_n, grid_n * grid_n, 1))
	program.buffer("stats_buf", 1, 32)
	program.texture("stats", 2, GpuProgram.TEX_2D, Vector3i(1, 1, 1))
	program.buffer("particle_buf", 3, maxi(particle_count, 1) * 32)
	program.texture("particles", 4, GpuProgram.TEX_2D, Vector3i(PARTICLE_ROW, particle_rows() * 2, 1))
	program.texture("volume", 5, GpuProgram.TEX_3D, Vector3i(volume_m, volume_m, volume_m),
			RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	program.texture("lines", 6, GpuProgram.TEX_2D, Vector3i(line_steps * 2 + 1, maxi(line_seeds, 1), 1))
	program.buffer("seed_buf", 7, maxi(line_seeds, 1) * 16)


func _push() -> PackedByteArray:
	return Glsl.push(PackedFloat32Array([
		t, param_a, param_b, extent,
		grid_n, volume_m, particle_count, float(_frame % 100000),
		0.0, flow_speed, particle_life, emitter_fraction,
		emitter.x, emitter.y, emitter.z, emitter_radius,
		line_seeds, line_steps, line_step_len, diff_step(),
	]))


func _gpu_update(recompute: bool, delta: float) -> void:
	_frame += 1
	var push := _push()
	if recompute:
		program.clear_buffer("stats_buf")
		program.dispatch(0, Vector3i(groups(grid_n, 4), groups(grid_n, 4), groups(grid_n, 4)), push)
		if volume_enabled:
			program.dispatch(1, Vector3i(groups(volume_m, 4), groups(volume_m, 4), groups(volume_m, 4)), push)
		program.dispatch(2, Vector3i.ONE, push)
	if particles_enabled and particle_count > 0:
		# dt goes in slot p[2].x of a per-dispatch copy of the push constants.
		var particle_push := push.duplicate()
		particle_push.encode_float(32, delta)
		program.dispatch(3, Vector3i(groups(particle_count, 64), 1, 1), particle_push)
	if lines_enabled and line_seeds > 0 and (recompute or _seeds_dirty):
		var seed_data := PackedFloat32Array()
		for i in line_seeds:
			var s := seeds[i] if i < seeds.size() else Vector3.ZERO
			seed_data.append_array([s.x, s.y, s.z, 1.0])
		program.upload_buffer("seed_buf", seed_data.to_byte_array())
		program.dispatch(4, Vector3i(groups(line_seeds, 8), 1, 1), push)
		_seeds_dirty = false


func _gpu_read_stats() -> void:
	program.read_back("stats", func(data: PackedByteArray) -> void:
		if data.size() >= 16:
			var f := data.to_float32_array()
			max_magnitude = maxf(f[0], 1e-6)
			max_divergence = f[1]
			max_curl = f[2])


# --- CPU baseline ---------------------------------------------------------------------------

func _cpu_update(recompute: bool, delta: float) -> void:
	if recompute:
		_cpu_grid()
		if volume_enabled:
			_cpu_volume()
		_cpu_texture_2d("stats", 1, 1, PackedFloat32Array([max_magnitude, max_divergence, max_curl, 0.0]))
	if particles_enabled and particle_count > 0:
		_cpu_particles_step(delta)
	if lines_enabled and line_seeds > 0 and (recompute or _seeds_dirty):
		_cpu_lines()
		_seeds_dirty = false


func _cpu_grid() -> void:
	var n := grid_n
	var data := PackedFloat32Array()
	data.resize(n * n * n * 4)
	var top := 0.0
	for k in n:
		for j in n:
			for i in n:
				var f := field(grid_point(i, j, k))
				var m := f.length()
				top = maxf(top, m)
				var o := ((j + n * k) * n + i) * 4
				data[o] = f.x
				data[o + 1] = f.y
				data[o + 2] = f.z
				data[o + 3] = m
	max_magnitude = maxf(top, 1e-6)
	_cpu_texture_2d("field", n, n * n, data)


func _cpu_volume() -> void:
	var m := volume_m
	var data := PackedFloat32Array()
	data.resize(m * m * m * 4)
	var top_div := 0.0
	var top_curl := 0.0
	var s := 2.0 * extent / float(m - 1)
	for k in m:
		for j in m:
			for i in m:
				var dc := div_curl(Vector3(-extent + s * i, -extent + s * j, -extent + s * k))
				var c: Vector3 = dc[1]
				top_div = maxf(top_div, absf(dc[0]))
				top_curl = maxf(top_curl, c.length())
				var o := ((k * m + j) * m + i) * 4
				data[o] = dc[0]
				data[o + 1] = c.x
				data[o + 2] = c.y
				data[o + 3] = c.z
	max_divergence = top_div
	max_curl = top_curl
	_cpu_texture_3d("volume", m, data)


func _random_point() -> Vector3:
	return Vector3(randf_range(-extent, extent), randf_range(-extent, extent), randf_range(-extent, extent))


func _spawn(i: int) -> Vector3:
	if emitter_radius > 0.0 and float(i) < float(particle_count) * emitter_fraction:
		return emitter + Vector3(randfn(0, 1), randfn(0, 1), randfn(0, 1)).limit_length(1.0) * emitter_radius
	return _random_point()


func _cpu_particles_step(delta: float) -> void:
	var count := particle_count
	if _cpu_particle_count != count:
		_cpu_particle_count = count
		_cpu_particles.resize(count * 8)
		_cpu_particles.fill(0.0)
	var k := flow_speed / maxf(max_magnitude, 1e-6) * delta
	for i in count:
		var o := i * 8
		var p := Vector3(_cpu_particles[o], _cpu_particles[o + 1], _cpu_particles[o + 2])
		var age := _cpu_particles[o + 3]
		if age <= 0.0 or absf(p.x) > extent or absf(p.y) > extent or absf(p.z) > extent:
			p = _spawn(i)
			age = particle_life * randf_range(0.5, 1.5)
		else:
			# dp/dt = F(p), classic RK4, time scaled so the fastest particle moves at flow_speed.
			var k1 := field(p)
			var k2 := field(p + k1 * (0.5 * k))
			var k3 := field(p + k2 * (0.5 * k))
			var k4 := field(p + k3 * k)
			p += (k1 + 2.0 * k2 + 2.0 * k3 + k4) * (k / 6.0)
			age -= delta
			if absf(p.x) > extent or absf(p.y) > extent or absf(p.z) > extent:
				age = 0.0
		var v := field(p)
		_cpu_particles[o] = p.x
		_cpu_particles[o + 1] = p.y
		_cpu_particles[o + 2] = p.z
		_cpu_particles[o + 3] = age
		_cpu_particles[o + 4] = v.x
		_cpu_particles[o + 5] = v.y
		_cpu_particles[o + 6] = v.z
		_cpu_particles[o + 7] = v.length() / maxf(max_magnitude, 1e-6)
	# Repack into the GPU layout: position rows, then velocity rows.
	var rows := particle_rows()
	var data := PackedFloat32Array()
	data.resize(PARTICLE_ROW * rows * 2 * 4)
	for i in count:
		var src := i * 8
		var dst := i * 4
		var dst_v := (rows * PARTICLE_ROW + i) * 4
		for c in 4:
			data[dst + c] = _cpu_particles[src + c]
			data[dst_v + c] = _cpu_particles[src + 4 + c]
	_cpu_texture_2d("particles", PARTICLE_ROW, rows * 2, data)


## Unit-speed field direction, RK4: one step of a field line (arc-length parametrised).
func _line_dir(p: Vector3) -> Vector3:
	var f := field(p)
	var m := f.length()
	return f / m if m > 1e-9 else Vector3.ZERO


func _cpu_lines() -> void:
	var w := line_steps * 2 + 1
	var data := PackedFloat32Array()
	data.resize(w * line_seeds * 4)
	for s in line_seeds:
		var seed := seeds[s] if s < seeds.size() else Vector3.ZERO
		for direction: float in [1.0, -1.0]:
			var p := seed
			var h := line_step_len * direction
			for j in line_steps + 1:
				if j > 0:
					var k1 := _line_dir(p)
					var k2 := _line_dir(p + k1 * (0.5 * h))
					var k3 := _line_dir(p + k2 * (0.5 * h))
					var k4 := _line_dir(p + k3 * h)
					var next := p + (k1 + 2.0 * k2 + 2.0 * k3 + k4) * (h / 6.0)
					if absf(next.x) <= extent * 1.05 and absf(next.y) <= extent * 1.05 \
							and absf(next.z) <= extent * 1.05:
						p = next
				var col := line_steps + j * int(direction)
				var o := (s * w + col) * 4
				data[o] = p.x
				data[o + 1] = p.y
				data[o + 2] = p.z
				data[o + 3] = field(p).length() / maxf(max_magnitude, 1e-6)
	_cpu_texture_2d("lines", w, line_seeds, data)


# --- GLSL kernels (appended after the generated Fu()) --------------------------------------

const KERNELS := """
vec3 Fs(vec3 p) { return fin3(Fu(p.x, p.y, p.z)); }
float EXT() { return pc.p[0].w; }

#ifdef PASS_GRID
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict writeonly image2D field_img;
layout(std430, set = 0, binding = 1) buffer Stats { uint v[8]; } stats;
void main() {
	load_common();
	int n = int(pc.p[1].x);
	ivec3 g = ivec3(gl_GlobalInvocationID);
	if (any(greaterThanEqual(g, ivec3(n)))) return;
	float e = EXT();
	vec3 p = -e + 2.0 * e * vec3(g) / float(n - 1);
	vec3 f = Fs(p);
	float m = length(f);
	if (bad(m)) { f = vec3(0.0); m = 0.0; }
	imageStore(field_img, ivec2(g.x, g.y + n * g.z), vec4(f, m));
	atomicMax(stats.v[0], ord(m));
}
#endif

#ifdef PASS_VOLUME
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;
layout(rgba16f, set = 0, binding = 5) uniform restrict writeonly image3D volume_img;
layout(std430, set = 0, binding = 1) buffer Stats { uint v[8]; } stats;
void main() {
	load_common();
	int m = int(pc.p[1].y);
	ivec3 g = ivec3(gl_GlobalInvocationID);
	if (any(greaterThanEqual(g, ivec3(m)))) return;
	float e = EXT();
	float h = pc.p[4].w;
	vec3 p = -e + 2.0 * e * vec3(g) / float(m - 1);
	vec3 dx = (Fs(p + vec3(h, 0, 0)) - Fs(p - vec3(h, 0, 0))) / (2.0 * h);
	vec3 dy = (Fs(p + vec3(0, h, 0)) - Fs(p - vec3(0, h, 0))) / (2.0 * h);
	vec3 dz = (Fs(p + vec3(0, 0, h)) - Fs(p - vec3(0, 0, h))) / (2.0 * h);
	float div_f = fin(dx.x + dy.y + dz.z);
	vec3 curl_f = fin3(vec3(dy.z - dz.y, dz.x - dx.z, dx.y - dy.x));
	imageStore(volume_img, g, vec4(div_f, curl_f));
	atomicMax(stats.v[1], ord(abs(div_f)));
	atomicMax(stats.v[2], ord(length(curl_f)));
}
#endif

#ifdef PASS_STATS
layout(local_size_x = 1) in;
layout(std430, set = 0, binding = 1) buffer Stats { uint v[8]; } stats;
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2D stats_img;
float stat(uint u) { return u == 0u ? 0.0 : unord(u); }
void main() {
	load_common();
	imageStore(stats_img, ivec2(0, 0), vec4(max(stat(stats.v[0]), 1e-6), stat(stats.v[1]), stat(stats.v[2]), 0.0));
}
#endif

#ifdef PASS_PARTICLES
layout(local_size_x = 64) in;
layout(std430, set = 0, binding = 1) buffer Stats { uint v[8]; } stats;
layout(std430, set = 0, binding = 3) buffer Particles { vec4 d[]; } parts;
layout(rgba32f, set = 0, binding = 4) uniform restrict writeonly image2D part_img;
void main() {
	load_common();
	uint i = gl_GlobalInvocationID.x;
	uint count = uint(pc.p[1].z);
	if (i >= count) return;
	float e = EXT();
	float dt = pc.p[2].x;
	float max_f = stats.v[0] == 0u ? 1.0 : max(unord(stats.v[0]), 1e-6);
	float k = pc.p[2].y / max_f * dt;
	vec4 s = parts.d[i * 2u];
	vec3 p = s.xyz;
	float age = s.w;
	if (age <= 0.0 || any(greaterThan(abs(p), vec3(e)))) {
		uint seed = pcg(i * 9781u + uint(pc.p[1].w) * 6271u);
		vec3 r = vec3(rand01(seed), rand01(seed), rand01(seed));
		float radius = pc.p[3].w;
		if (radius > 0.0 && float(i) < float(count) * pc.p[2].w) {
			vec3 d = r * 2.0 - 1.0;
			p = pc.p[3].xyz + d * radius * rand01(seed);
		} else {
			p = (r * 2.0 - 1.0) * e;
		}
		age = pc.p[2].z * (0.5 + rand01(seed));
	} else {
		// dp/dt = F(p), classic RK4; time scaled so the fastest particle moves at flow_speed.
		vec3 k1 = Fs(p);
		vec3 k2 = Fs(p + k1 * (0.5 * k));
		vec3 k3 = Fs(p + k2 * (0.5 * k));
		vec3 k4 = Fs(p + k3 * k);
		p += (k1 + 2.0 * k2 + 2.0 * k3 + k4) * (k / 6.0);
		age -= dt;
		// Left the box: hide now (age 0), respawn next frame.
		if (any(greaterThan(abs(p), vec3(e)))) age = 0.0;
	}
	vec3 v = Fs(p);
	parts.d[i * 2u] = vec4(p, age);
	parts.d[i * 2u + 1u] = vec4(v, length(v) / max_f);
	int rows = (int(count) + 255) / 256;
	ivec2 at = ivec2(int(i) % 256, int(i) / 256);
	imageStore(part_img, at, vec4(p, age));
	imageStore(part_img, at + ivec2(0, rows), vec4(v, length(v) / max_f));
}
#endif

#ifdef PASS_LINES
layout(local_size_x = 8) in;
layout(std430, set = 0, binding = 1) buffer Stats { uint v[8]; } stats;
layout(std430, set = 0, binding = 7) buffer Seeds { vec4 d[]; } seeds;
layout(rgba32f, set = 0, binding = 6) uniform restrict writeonly image2D line_img;
vec3 dir_at(vec3 p) { vec3 f = Fs(p); float m = length(f); return m > 1e-9 ? f / m : vec3(0.0); }
void main() {
	load_common();
	int s = int(gl_GlobalInvocationID.x);
	if (s >= int(pc.p[4].x)) return;
	int steps = int(pc.p[4].y);
	float e = EXT() * 1.05;
	float max_f = stats.v[0] == 0u ? 1.0 : max(unord(stats.v[0]), 1e-6);
	for (int pass_dir = 0; pass_dir < 2; pass_dir++) {
		float h = pc.p[4].z * (pass_dir == 0 ? 1.0 : -1.0);
		vec3 p = seeds.d[s].xyz;
		for (int j = 0; j <= steps; j++) {
			if (j > 0) {
				vec3 k1 = dir_at(p);
				vec3 k2 = dir_at(p + k1 * (0.5 * h));
				vec3 k3 = dir_at(p + k2 * (0.5 * h));
				vec3 k4 = dir_at(p + k3 * h);
				vec3 next = p + (k1 + 2.0 * k2 + 2.0 * k3 + k4) * (h / 6.0);
				if (all(lessThanEqual(abs(next), vec3(e)))) p = next;
			}
			int col = steps + (pass_dir == 0 ? j : -j);
			imageStore(line_img, ivec2(col, s), vec4(p, length(Fs(p)) / max_f));
		}
	}
}
#endif
"""
