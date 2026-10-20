class_name ScalarSurfaceEngine
extends FieldEngine
## z = f(x, y) on the square [-E, E]². Outputs:
##   "surface" R × R RGBA32F: texel (i, j) = (f, ∂f/∂x, ∂f/∂y, |∇f|) at
##             x = -E + 2E i/(R-1), y = -E + 2E j/(R-1)
##   "stats"   1 × 1 RGBA32F: (min f, max f, max |∇f|, 0)
## The partial derivatives are central differences of f itself (step H).

const VARIABLES := ["x", "y", "t", "a", "b"]
const H_REL := 1e-3

var extent := 2.0
var resolution := 128
var expr: MathExpr
var text := ""
var min_value := 0.0
var max_value := 1.0
var max_gradient := 1.0

var _args := [0.0, 0.0, 0.0, 0.0, 0.0]


func _init() -> void:
	super("surf")


static func compile_text(source: String) -> MathExpr:
	return MathExpr.compile(source, PackedStringArray(VARIABLES))


func set_function(source: String) -> String:
	var e := compile_text(source)
	if not e.is_valid():
		return e.error
	expr = e
	text = source.strip_edges()
	rebuild()
	return ""


func is_time_dependent() -> bool:
	return expr != null and expr.uses("t")


func f(x: float, y: float) -> float:
	_args[0] = x
	_args[1] = y
	_args[2] = t
	_args[3] = param_a
	_args[4] = param_b
	var v := expr.evaluate(_args)
	return v if is_finite(v) else 0.0


func diff_step() -> float:
	return H_REL * maxf(extent, 1.0)


func gradient(x: float, y: float) -> Vector2:
	var h := diff_step()
	return Vector2(f(x + h, y) - f(x - h, y), f(x, y + h) - f(x, y - h)) / (2.0 * h)


func sample_xy(i: int, j: int) -> Vector2:
	var s := 2.0 * extent / float(resolution - 1)
	return Vector2(-extent + s * i, -extent + s * j)


func _gpu_source() -> String:
	return Glsl.HEADER + Glsl.scalar_function("fu", PackedStringArray(["x", "y"]), expr) + KERNELS


func _gpu_passes() -> Array:
	return [
		{"define": "PASS_SURFACE", "bindings": ["surface", "stats_buf"]},
		{"define": "PASS_STATS", "bindings": ["stats_buf", "stats"]},
	]


func _gpu_resources() -> void:
	program.texture("surface", 0, GpuProgram.TEX_2D, Vector3i(resolution, resolution, 1))
	program.buffer("stats_buf", 1, 16)
	program.texture("stats", 2, GpuProgram.TEX_2D, Vector3i(1, 1, 1))


func _gpu_update(recompute: bool, _delta: float) -> void:
	if not recompute:
		return
	var push := Glsl.push(PackedFloat32Array([t, param_a, param_b, extent, resolution, diff_step()]))
	program.clear_buffer("stats_buf")
	program.dispatch(0, Vector3i(groups(resolution, 8), groups(resolution, 8), 1), push)
	program.dispatch(1, Vector3i.ONE, push)


func _gpu_read_stats() -> void:
	program.read_back("stats", func(data: PackedByteArray) -> void:
		if data.size() >= 16:
			var s := data.to_float32_array()
			min_value = s[0]
			max_value = s[1]
			max_gradient = s[2])


func _cpu_update(recompute: bool, _delta: float) -> void:
	if not recompute:
		return
	var r := resolution
	var data := PackedFloat32Array()
	data.resize(r * r * 4)
	var lo := INF
	var hi := -INF
	var top_grad := 0.0
	for j in r:
		for i in r:
			var p := sample_xy(i, j)
			var v := f(p.x, p.y)
			var g := gradient(p.x, p.y)
			lo = minf(lo, v)
			hi = maxf(hi, v)
			top_grad = maxf(top_grad, g.length())
			var o := (j * r + i) * 4
			data[o] = v
			data[o + 1] = g.x
			data[o + 2] = g.y
			data[o + 3] = g.length()
	min_value = lo
	max_value = hi
	max_gradient = top_grad
	_cpu_texture_2d("surface", r, r, data)
	_cpu_texture_2d("stats", 1, 1, PackedFloat32Array([lo, hi, top_grad, 0.0]))


const KERNELS := """
float fs(float x, float y) { return fin(fu(x, y)); }

#ifdef PASS_SURFACE
layout(local_size_x = 8, local_size_y = 8) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict writeonly image2D surface_img;
layout(std430, set = 0, binding = 1) buffer Stats { uint v[4]; } stats;
void main() {
	load_common();
	int r = int(pc.p[1].x);
	ivec2 g = ivec2(gl_GlobalInvocationID.xy);
	if (g.x >= r || g.y >= r) return;
	float e = pc.p[0].w;
	float h = pc.p[1].y;
	vec2 p = -e + 2.0 * e * vec2(g) / float(r - 1);
	float v = fs(p.x, p.y);
	vec2 grad = vec2(fs(p.x + h, p.y) - fs(p.x - h, p.y), fs(p.x, p.y + h) - fs(p.x, p.y - h)) / (2.0 * h);
	grad = vec2(fin(grad.x), fin(grad.y));
	imageStore(surface_img, g, vec4(v, grad, length(grad)));
	// min f is stored as max(-f) so a cleared (zero) buffer works for both.
	atomicMax(stats.v[0], ord(-v));
	atomicMax(stats.v[1], ord(v));
	atomicMax(stats.v[2], ord(length(grad)));
}
#endif

#ifdef PASS_STATS
layout(local_size_x = 1) in;
layout(std430, set = 0, binding = 1) buffer Stats { uint v[4]; } stats;
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2D stats_img;
void main() {
	load_common();
	imageStore(stats_img, ivec2(0, 0), vec4(-unord(stats.v[0]), unord(stats.v[1]), unord(stats.v[2]), 0.0));
}
#endif
"""
