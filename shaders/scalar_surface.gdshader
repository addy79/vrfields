// z = f(x, y) displaced on the GPU from the compute shader's surface texture
// (R × R, texel = (f, fx, fy, |∇f|)). The mesh is a grid whose UV picks the texel.
// Colour: height (turbo) or |∇f|, with level curves f = const drawn on top.
shader_type spatial;
render_mode cull_disabled;

#include "res://shaders/common.gdshaderinc"

uniform sampler2D surface_tex : filter_nearest;
uniform sampler2D stats_tex : filter_nearest;
uniform int resolution = 128;
uniform float extent = 2.0;
// Display height = (f - z_offset) * z_scale (math units).
uniform float z_scale = 1.0;
uniform float z_offset = 0.0;
// 0: colour by height, 1: by |∇f|.
uniform int color_mode = 0;
uniform float level_count = 14.0;

varying float v_f;
varying float v_grad;

void vertex() {
	ivec2 g = ivec2(round(UV * float(resolution - 1)));
	vec4 s = texelFetch(surface_tex, g, 0);
	vec2 xy = -extent + 2.0 * extent * vec2(g) / float(resolution - 1);
	VERTEX = to_godot(vec3(xy, (s.x - z_offset) * z_scale));
	NORMAL = normalize(to_godot(vec3(-s.y * z_scale, -s.z * z_scale, 1.0)));
	v_f = s.x;
	v_grad = s.w;
}

void fragment() {
	vec4 stats = texelFetch(stats_tex, ivec2(0, 0), 0);
	float lo = stats.x;
	float hi = max(stats.y, lo + 1e-6);
	float h = (v_f - lo) / (hi - lo);
	vec3 col = color_mode == 0 ? turbo(0.08 + 0.82 * h) : turbo(0.05 + 0.85 * v_grad / max(stats.z, 1e-6));
	float c = h * level_count;
	float line = 1.0 - smoothstep(0.0, 1.2 * fwidth(c), abs(fract(c + 0.5) - 0.5));
	col = mix(col, vec3(0.05), line * 0.7);
	ALBEDO = FRONT_FACING ? col : col * 0.55;
	ROUGHNESS = 0.55;
}
