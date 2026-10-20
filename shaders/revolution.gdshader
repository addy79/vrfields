// Solid of revolution about the math x-axis, built in the vertex shader from the
// profile texture (R × 1, texel = (outer radius, inner radius, x, 0)).
// UV.x = profile position (0..1), UV.y = angle fraction or radial fraction,
// UV2.x = part: 0 outer wall, 1 inner wall, 2 end cap at x0, 3 end cap at x1,
// 4 flat region at angle 0, 5 flat region at the sweep angle.
// The solid is swept from angle 0 (the region standing upright, facing the
// viewer) to `sweep` (animated 0 -> 2π).
shader_type spatial;
render_mode cull_disabled;

#include "res://shaders/common.gdshaderinc"

uniform sampler2D profile_tex : filter_nearest;
uniform int resolution = 256;
uniform float sweep = 6.2831853;
uniform vec4 solid_color : source_color = vec4(0.25, 0.6, 0.95, 1.0);
uniform vec4 region_color : source_color = vec4(1.0, 0.75, 0.2, 1.0);
uniform float opacity = 0.75;
// The flat region being swept (hidden once the solid is complete).
uniform bool show_region = true;

varying float v_part;

// Profile at fraction u (linear interpolation between texels).
vec4 profile(float u) {
	float x = clamp(u, 0.0, 1.0) * float(resolution - 1);
	int i = int(floor(x));
	vec4 a = texelFetch(profile_tex, ivec2(i, 0), 0);
	vec4 b = texelFetch(profile_tex, ivec2(min(i + 1, resolution - 1), 0), 0);
	return mix(a, b, x - float(i));
}

void vertex() {
	int part = int(round(UV2.x));
	float u = part == 2 ? 0.0 : (part == 3 ? 1.0 : UV.x);
	vec4 pr = profile(u);
	float du = 1.0 / float(resolution - 1);
	vec4 pr1 = profile(u + du);
	vec4 pr0 = profile(u - du);
	float dx = max(pr1.z - pr0.z, 1e-6);
	float angle = (part == 4) ? 0.0 : (part == 5 ? sweep : UV.y * sweep);
	float radius;
	vec3 n_m;
	vec2 dir = vec2(-sin(angle), cos(angle));
	if (part == 0 || part == 1) {
		radius = part == 0 ? pr.x : pr.y;
		float slope = ((part == 0 ? pr1.x : pr1.y) - (part == 0 ? pr0.x : pr0.y)) / dx;
		n_m = normalize(vec3(-slope, dir));
		if (part == 1) n_m = -n_m;
	} else if (part == 2 || part == 3) {
		radius = mix(pr.y, pr.x, UV.y);
		angle = UV.x * sweep;
		dir = vec2(-sin(angle), cos(angle));
		n_m = vec3(part == 2 ? -1.0 : 1.0, 0.0, 0.0);
	} else {
		radius = mix(pr.y, pr.x, UV.y);
		n_m = vec3(0.0, -dir.y, dir.x) * (part == 4 ? -1.0 : 1.0);
	}
	if (part >= 4 && !show_region) radius = 0.0;
	vec3 p = vec3(pr.z, radius * dir);
	VERTEX = to_godot(p);
	NORMAL = to_godot(n_m);
	v_part = float(part);
}

void fragment() {
	bool region = v_part > 3.5;
	vec3 col = region ? region_color.rgb : solid_color.rgb;
	ALBEDO = FRONT_FACING ? col : col * 0.6;
	ALPHA = region ? 0.95 : opacity;
	ROUGHNESS = 0.4;
}
