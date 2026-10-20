class_name ProfileEngine
extends FieldEngine
## Profile curves for a solid of revolution about the x-axis: outer radius f(x)
## and inner radius g(x) (g = 0 gives the disk method, otherwise washers), on
## [x0, x1]. Outputs:
##   "profile" R × 1 RGBA32F: texel i = (|f(x)|, |g(x)|, x, 0), x = x0 + (x1-x0) i/(R-1)
##   "stats"   1 × 1 RGBA32F: (max radius, 0, 0, 0)
## The revolved surface itself is built in the vertex shader from this texture.
## Volume (CPU, both backends): V = π ∫ |f² − g²| dx by composite Simpson's rule.

const VARIABLES := ["x", "t", "a", "b"]
const SIMPSON_INTERVALS := 2000

var resolution := 256
var x_range := Vector2(0.0, 4.0)
var outer: MathExpr
var inner: MathExpr
var outer_text := ""
var inner_text := "0"
var max_radius := 1.0

var _args := [0.0, 0.0, 0.0, 0.0]


func _init() -> void:
	super("prof")


static func compile_text(source: String) -> MathExpr:
	return MathExpr.compile(source, PackedStringArray(VARIABLES))


func set_profile(outer_source: String, inner_source: String, x_min: float, x_max: float) -> String:
	var o := compile_text(outer_source)
	if not o.is_valid():
		return "f(x): " + o.error
	var i := compile_text(inner_source if not inner_source.strip_edges().is_empty() else "0")
	if not i.is_valid():
		return "g(x): " + i.error
	if not x_max > x_min:
		return "Need x min < x max"
	outer = o
	inner = i
	outer_text = outer_source.strip_edges()
	inner_text = inner_source.strip_edges() if not inner_source.strip_edges().is_empty() else "0"
	x_range = Vector2(x_min, x_max)
	rebuild()
	return ""


func is_time_dependent() -> bool:
	return outer != null and (outer.uses("t") or inner.uses("t"))


func _eval(e: MathExpr, x: float) -> float:
	_args[0] = x
	_args[1] = t
	_args[2] = param_a
	_args[3] = param_b
	var v := e.evaluate(_args)
	return absf(v) if is_finite(v) else 0.0


func outer_radius(x: float) -> float:
	return _eval(outer, x)


func inner_radius(x: float) -> float:
	return _eval(inner, x)


## Cross-sectional area at x: π |f² − g²|.
func area(x: float) -> float:
	return PI * absf(outer_radius(x) ** 2 - inner_radius(x) ** 2)


## V = ∫ area dx from x0 to `x_end`, composite Simpson's rule.
func volume_to(x_end: float) -> float:
	var a := x_range.x
	var b := clampf(x_end, x_range.x, x_range.y)
	if b <= a:
		return 0.0
	var n := SIMPSON_INTERVALS
	var h := (b - a) / n
	var total := area(a) + area(b)
	for i in range(1, n):
		total += (4.0 if i % 2 == 1 else 2.0) * area(a + h * i)
	return total * h / 3.0


## Riemann sum with `count` disks/washers sampled at midpoints.
func riemann_volume(count: int) -> float:
	var dx := (x_range.y - x_range.x) / count
	var total := 0.0
	for i in count:
		total += area(x_range.x + dx * (i + 0.5)) * dx
	return total


func _gpu_source() -> String:
	var args := PackedStringArray(["x"])
	return Glsl.HEADER + Glsl.scalar_function("fo", args, outer) \
			+ Glsl.scalar_function("fi", args, inner) + KERNELS


func _gpu_passes() -> Array:
	return [
		{"define": "PASS_PROFILE", "bindings": ["profile", "stats_buf"]},
		{"define": "PASS_STATS", "bindings": ["stats_buf", "stats"]},
	]


func _gpu_resources() -> void:
	program.texture("profile", 0, GpuProgram.TEX_2D, Vector3i(resolution, 1, 1))
	program.buffer("stats_buf", 1, 16)
	program.texture("stats", 2, GpuProgram.TEX_2D, Vector3i(1, 1, 1))


func _gpu_update(recompute: bool, _delta: float) -> void:
	if not recompute:
		return
	var push := Glsl.push(PackedFloat32Array([t, param_a, param_b, 0.0, resolution, x_range.x, x_range.y]))
	program.clear_buffer("stats_buf")
	program.dispatch(0, Vector3i(groups(resolution, 64), 1, 1), push)
	program.dispatch(1, Vector3i.ONE, push)


func _gpu_read_stats() -> void:
	program.read_back("stats", func(data: PackedByteArray) -> void:
		if data.size() >= 16:
			max_radius = maxf(data.to_float32_array()[0], 1e-6))


func _cpu_update(recompute: bool, _delta: float) -> void:
	if not recompute:
		return
	var data := PackedFloat32Array()
	data.resize(resolution * 4)
	var top := 0.0
	for i in resolution:
		var x := lerpf(x_range.x, x_range.y, float(i) / (resolution - 1))
		var fo := outer_radius(x)
		var fi := inner_radius(x)
		top = maxf(top, maxf(fo, fi))
		data[i * 4] = fo
		data[i * 4 + 1] = fi
		data[i * 4 + 2] = x
	max_radius = maxf(top, 1e-6)
	_cpu_texture_2d("profile", resolution, 1, data)
	_cpu_texture_2d("stats", 1, 1, PackedFloat32Array([max_radius, 0.0, 0.0, 0.0]))


const KERNELS := """
#ifdef PASS_PROFILE
layout(local_size_x = 64) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict writeonly image2D profile_img;
layout(std430, set = 0, binding = 1) buffer Stats { uint v[4]; } stats;
void main() {
	load_common();
	int n = int(pc.p[1].x);
	int i = int(gl_GlobalInvocationID.x);
	if (i >= n) return;
	float x = mix(pc.p[1].y, pc.p[1].z, float(i) / float(n - 1));
	float ro = abs(fin(fo(x)));
	float ri = abs(fin(fi(x)));
	imageStore(profile_img, ivec2(i, 0), vec4(ro, ri, x, 0.0));
	atomicMax(stats.v[0], ord(max(ro, ri)));
}
#endif

#ifdef PASS_STATS
layout(local_size_x = 1) in;
layout(std430, set = 0, binding = 1) buffer Stats { uint v[4]; } stats;
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2D stats_img;
void main() {
	load_common();
	imageStore(stats_img, ivec2(0, 0), vec4(max(unord(stats.v[0]), 1e-6), 0.0, 0.0, 0.0));
}
#endif
"""
