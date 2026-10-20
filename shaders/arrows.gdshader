// Instanced arrows driven entirely by a data texture: instance i reads its
// vector with texelFetch, so moving 30 000 arrows costs the CPU nothing.
// mode 0: 3D grid of F from the "field" texture (N × N², texel (i, j + N k)).
// mode 1: 2D grid of ∇f from a scalar-surface texture (R × R, (f, fx, fy, |∇f|)),
//         drawn flat at height base_z (the gradient lives in the xy-plane).
// The mesh is a unit arrow along +y: UV.x = 0 shaft (y in [0, 1]), 1 head.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

#include "res://shaders/common.gdshaderinc"

uniform sampler2D data_tex : filter_nearest;
uniform sampler2D stats_tex : filter_nearest;
uniform int mode = 0;
uniform int grid_n = 12;
// mode 1: arrows per side and the surface texture resolution.
uniform int surface_res = 128;
uniform float base_z = -2.0;
uniform float extent = 2.0;
// Arrow length at max |F|, as a fraction of the grid spacing.
uniform float length_scale = 0.9;
uniform float thickness = 0.06;
// Show only arrows inside a slab |coord[axis] - slab_pos| <= slab_half (axis 0 = off, 1..3 = x, y, z).
uniform int slab_axis = 0;
uniform float slab_pos = 0.0;
uniform float slab_half = 0.2;
// Show only arrows within this distance of focus (<= 0: off).
uniform vec3 focus = vec3(0.0);
uniform float focus_radius = 0.0;
// Fixed colour scale (> 0) instead of the live max from stats_tex.
uniform float max_override = -1.0;

varying vec3 v_color;

void vertex() {
	int id = INSTANCE_ID;
	int n = grid_n;
	ivec3 g = ivec3(id % n, (id / n) % n, id / (n * n));
	vec3 vec_m;
	float mag;
	float top;
	vec3 center_m;
	float spacing = 2.0 * extent / float(n - 1);
	vec4 stats = texelFetch(stats_tex, ivec2(0, 0), 0);
	if (mode == 0) {
		vec4 f = texelFetch(data_tex, ivec2(g.x, g.y + n * g.z), 0);
		vec_m = f.xyz;
		mag = f.w;
		top = max_override > 0.0 ? max_override : stats.x;
		center_m = -extent + spacing * vec3(g);
	} else {
		ivec2 texel = ivec2(round(vec2(g.xy) * float(surface_res - 1) / float(n - 1)));
		vec4 s = texelFetch(data_tex, texel, 0);
		vec_m = vec3(s.y, s.z, 0.0);
		mag = s.w;
		top = max_override > 0.0 ? max_override : stats.z;
		center_m = vec3(-extent + spacing * vec2(g.xy), base_z);
		if (g.z > 0) mag = 0.0;  // only one layer
	}
	bool hidden = mag < 1e-6 || top <= 0.0;
	if (slab_axis > 0 && abs(center_m[slab_axis - 1] - slab_pos) > slab_half) hidden = true;
	if (focus_radius > 0.0 && distance(center_m, focus) > focus_radius) hidden = true;

	float t = clamp(mag / max(top, 1e-6), 0.0, 1.0);
	v_color = turbo(t);
	float len = hidden ? 0.0 : spacing * length_scale * mix(0.25, 1.0, sqrt(t));
	float head = min(len * 0.4, spacing * 0.3);
	float radius = spacing * thickness;
	vec3 dir = normalize(to_godot(vec_m) + vec3(0.0, 1e-12, 0.0));
	mat3 fr = frame_from_dir(dir);
	bool is_head = UV.x > 0.5;
	float y = is_head ? (len - head) + VERTEX.y * head : VERTEX.y * (len - head);
	float r = hidden ? 0.0 : radius;
	vec3 local = vec3(VERTEX.x * r, y, VERTEX.z * r);
	VERTEX = to_godot(center_m) - dir * len * 0.5 + fr * local;
	NORMAL = normalize(fr * NORMAL);
}

void fragment() {
	ALBEDO = v_color;
	EMISSION = v_color * 0.25;
	ROUGHNESS = 0.45;
}
