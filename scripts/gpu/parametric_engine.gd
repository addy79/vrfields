class_name ParametricEngine
extends FieldEngine
## r(u, v) = (x(u, v), y(u, v), z(u, v)) for u in [u0, u1], v in [v0, v1]. Outputs:
##   "surface" R × R RGBA32F: texel (i, j) = (r, K) with u = u0 + (u1-u0) i/(R-1), v likewise,
##             K = Gaussian curvature (LN - M²)/(EG - F²) from the first and second
##             fundamental forms, all derivatives by central differences of r.
##   "stats"   1 × 1 RGBA32F: (max |coordinate|, max |K| (clamped), 0, 0)

const VARIABLES := ["u", "v", "t", "a", "b"]
## Difference step relative to the parameter range. Second derivatives in float32
## need a larger step than first ones (round-off grows like eps / h²).
const H_REL := 4e-3
const K_CLAMP := 50.0

var resolution := 160
var u_range := Vector2(0.0, TAU)
var v_range := Vector2(0.0, TAU)
var exprs: Array[MathExpr] = []
var text := ""
var max_coord := 1.0
var max_curvature := 1.0

var _args := [0.0, 0.0, 0.0, 0.0, 0.0]


func _init() -> void:
	super("param")


static func compile_text(source: String) -> Dictionary:
	return MathExpr.compile_tuple(source, PackedStringArray(VARIABLES), 3)


func set_surface(source: String, u_min: float, u_max: float, v_min: float, v_max: float) -> String:
	var result := compile_text(source)
	if not result.error.is_empty():
		return result.error
	if not (u_max > u_min and v_max > v_min):
		return "Ranges need min < max"
	exprs.assign(result.exprs)
	text = source.strip_edges()
	u_range = Vector2(u_min, u_max)
	v_range = Vector2(v_min, v_max)
	rebuild()
	return ""


func is_time_dependent() -> bool:
	for e in exprs:
		if e.uses("t"):
			return true
	return false


func r(u: float, v: float) -> Vector3:
	_args[0] = u
	_args[1] = v
	_args[2] = t
	_args[3] = param_a
	_args[4] = param_b
	var p := Vector3(exprs[0].evaluate(_args), exprs[1].evaluate(_args), exprs[2].evaluate(_args))
	for i in 3:
		if not is_finite(p[i]):
			p[i] = 0.0
	return p


func steps() -> Vector2:
	return Vector2(u_range.y - u_range.x, v_range.y - v_range.x) * H_REL


func uv_at(i: int, j: int) -> Vector2:
	return Vector2(lerpf(u_range.x, u_range.y, float(i) / (resolution - 1)),
			lerpf(v_range.x, v_range.y, float(j) / (resolution - 1)))


## {"r_u", "r_v", "normal", "K", "H"} at (u, v) (H = mean curvature).
func frame(u: float, v: float) -> Dictionary:
	var h := steps()
	var p := r(u, v)
	var ru := (r(u + h.x, v) - r(u - h.x, v)) / (2.0 * h.x)
	var rv := (r(u, v + h.y) - r(u, v - h.y)) / (2.0 * h.y)
	var ruu := (r(u + h.x, v) - 2.0 * p + r(u - h.x, v)) / (h.x * h.x)
	var rvv := (r(u, v + h.y) - 2.0 * p + r(u, v - h.y)) / (h.y * h.y)
	var ruv := (r(u + h.x, v + h.y) - r(u + h.x, v - h.y) - r(u - h.x, v + h.y) + r(u - h.x, v - h.y)) / (4.0 * h.x * h.y)
	var n := ru.cross(rv)
	var curvature := 0.0
	var mean := 0.0
	if n.length() > 1e-9:
		n = n.normalized()
		var e := ru.dot(ru)
		var f := ru.dot(rv)
		var g := rv.dot(rv)
		var l := ruu.dot(n)
		var m := ruv.dot(n)
		var nn := rvv.dot(n)
		var den := e * g - f * f
		if absf(den) > 1e-12:
			curvature = (l * nn - m * m) / den
			mean = (e * nn - 2.0 * f * m + g * l) / (2.0 * den)
	return {"point": p, "r_u": ru, "r_v": rv, "normal": n, "K": curvature, "H": mean}


func _gpu_source() -> String:
	return Glsl.HEADER + Glsl.vec3_function("ru_fn", PackedStringArray(["u", "v"]), exprs) + KERNELS


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
	var h := steps()
	var push := Glsl.push(PackedFloat32Array([t, param_a, param_b, 0.0,
			resolution, h.x, h.y, K_CLAMP, u_range.x, u_range.y, v_range.x, v_range.y]))
	program.clear_buffer("stats_buf")
	program.dispatch(0, Vector3i(groups(resolution, 8), groups(resolution, 8), 1), push)
	program.dispatch(1, Vector3i.ONE, push)


func _gpu_read_stats() -> void:
	program.read_back("stats", func(data: PackedByteArray) -> void:
		if data.size() >= 16:
			var s := data.to_float32_array()
			max_coord = maxf(s[0], 1e-6)
			max_curvature = s[1])


func _cpu_update(recompute: bool, _delta: float) -> void:
	if not recompute:
		return
	var n := resolution
	var data := PackedFloat32Array()
	data.resize(n * n * 4)
	var top := 0.0
	var top_k := 0.0
	for j in n:
		for i in n:
			var uv := uv_at(i, j)
			var fr := frame(uv.x, uv.y)
			var p: Vector3 = fr.point
			var k := clampf(fr.K, -K_CLAMP, K_CLAMP)
			top = maxf(top, maxf(absf(p.x), maxf(absf(p.y), absf(p.z))))
			top_k = maxf(top_k, absf(k))
			var o := (j * n + i) * 4
			data[o] = p.x
			data[o + 1] = p.y
			data[o + 2] = p.z
			data[o + 3] = k
	max_coord = maxf(top, 1e-6)
	max_curvature = top_k
	_cpu_texture_2d("surface", n, n, data)
	_cpu_texture_2d("stats", 1, 1, PackedFloat32Array([max_coord, top_k, 0.0, 0.0]))


const KERNELS := """
vec3 rs(float u, float v) { return fin3(ru_fn(u, v)); }

#ifdef PASS_SURFACE
layout(local_size_x = 8, local_size_y = 8) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict writeonly image2D surface_img;
layout(std430, set = 0, binding = 1) buffer Stats { uint v[4]; } stats;
void main() {
	load_common();
	int n = int(pc.p[1].x);
	ivec2 g = ivec2(gl_GlobalInvocationID.xy);
	if (g.x >= n || g.y >= n) return;
	vec2 h = pc.p[1].yz;
	float u = mix(pc.p[2].x, pc.p[2].y, float(g.x) / float(n - 1));
	float v = mix(pc.p[2].z, pc.p[2].w, float(g.y) / float(n - 1));
	vec3 p = rs(u, v);
	vec3 pu1 = rs(u + h.x, v), pu0 = rs(u - h.x, v);
	vec3 pv1 = rs(u, v + h.y), pv0 = rs(u, v - h.y);
	vec3 ru = (pu1 - pu0) / (2.0 * h.x);
	vec3 rv = (pv1 - pv0) / (2.0 * h.y);
	vec3 ruu = (pu1 - 2.0 * p + pu0) / (h.x * h.x);
	vec3 rvv = (pv1 - 2.0 * p + pv0) / (h.y * h.y);
	vec3 ruv = (rs(u + h.x, v + h.y) - rs(u + h.x, v - h.y) - rs(u - h.x, v + h.y) + rs(u - h.x, v - h.y)) / (4.0 * h.x * h.y);
	vec3 nrm = cross(ru, rv);
	float k = 0.0;
	if (length(nrm) > 1e-9) {
		nrm = normalize(nrm);
		float E = dot(ru, ru), F = dot(ru, rv), G = dot(rv, rv);
		float L = dot(ruu, nrm), M = dot(ruv, nrm), N = dot(rvv, nrm);
		float den = E * G - F * F;
		if (abs(den) > 1e-12) k = (L * N - M * M) / den;
	}
	k = clamp(fin(k), -pc.p[1].w, pc.p[1].w);
	imageStore(surface_img, g, vec4(p, k));
	atomicMax(stats.v[0], ord(max(abs(p.x), max(abs(p.y), abs(p.z)))));
	atomicMax(stats.v[1], ord(abs(k)));
}
#endif

#ifdef PASS_STATS
layout(local_size_x = 1) in;
layout(std430, set = 0, binding = 1) buffer Stats { uint v[4]; } stats;
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2D stats_img;
void main() {
	load_common();
	imageStore(stats_img, ivec2(0, 0), vec4(max(unord(stats.v[0]), 1e-6), unord(stats.v[1]), 0.0, 0.0));
}
#endif
"""
