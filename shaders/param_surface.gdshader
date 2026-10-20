// Parametric surface r(u, v) placed by the GPU from the compute shader's texture
// (R × R, texel = (r, K)). Normals come from neighbouring texels (r_u × r_v).
// Colour: Gaussian curvature K (red > 0 elliptic, blue < 0 hyperbolic) or a
// (u, v) checkerboard; the back side is tinted so one-sided surfaces show it.
shader_type spatial;
render_mode cull_disabled;

#include "res://shaders/common.gdshaderinc"

uniform sampler2D surface_tex : filter_nearest;
uniform sampler2D stats_tex : filter_nearest;
uniform int resolution = 160;
// Math units -> display units (fits the surface into the domain box).
uniform float fit_scale = 1.0;
// 0: curvature, 1: checkerboard, 2: normal direction.
uniform int color_mode = 0;
uniform float checks = 12.0;

varying float v_k;
varying vec2 v_uv;
varying vec3 v_normal_m;

void vertex() {
	ivec2 g = ivec2(round(UV * float(resolution - 1)));
	int last = resolution - 1;
	vec3 p = texelFetch(surface_tex, g, 0).xyz;
	vec3 pu = texelFetch(surface_tex, ivec2(min(g.x + 1, last), g.y), 0).xyz
			- texelFetch(surface_tex, ivec2(max(g.x - 1, 0), g.y), 0).xyz;
	vec3 pv = texelFetch(surface_tex, ivec2(g.x, min(g.y + 1, last)), 0).xyz
			- texelFetch(surface_tex, ivec2(g.x, max(g.y - 1, 0)), 0).xyz;
	vec3 n = cross(pu, pv);
	n = length(n) > 1e-12 ? normalize(n) : vec3(0.0, 0.0, 1.0);
	VERTEX = to_godot(p * fit_scale);
	NORMAL = to_godot(n);
	v_normal_m = n;
	v_k = texelFetch(surface_tex, g, 0).w;
	v_uv = UV;
}

void fragment() {
	vec4 stats = texelFetch(stats_tex, ivec2(0, 0), 0);
	vec3 col;
	if (color_mode == 0) {
		// Signed square root keeps small curvatures visible next to large ones.
		float s = v_k / max(stats.y, 1e-6);
		col = diverging(sign(s) * sqrt(abs(s)));
	} else if (color_mode == 1) {
		vec2 c = floor(v_uv * checks);
		col = mod(c.x + c.y, 2.0) < 0.5 ? vec3(0.95, 0.75, 0.2) : vec3(0.15, 0.45, 0.85);
	} else {
		col = abs(v_normal_m) * 0.8 + 0.15;
	}
	ALBEDO = FRONT_FACING ? col : mix(col, vec3(0.55, 0.2, 0.6), 0.6);
	ROUGHNESS = 0.5;
}
