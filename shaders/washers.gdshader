// Disks / washers sized by the profile texture. Instance i covers
// [x0 + i dx, x0 + (i+1) dx] with radii taken at its midpoint (the Riemann
// sum the volume integral is the limit of). With count = 1 and slice_mode on,
// draws one thin cross-section at slice_u instead.
// Mesh: UV.x = angle fraction, UV.y = 0/1 (left/right face of the slab),
// UV2.x = part: 0 outer wall, 1 inner wall, 2 face (UV2.y = radial fraction).
shader_type spatial;
render_mode cull_disabled;

#include "res://shaders/common.gdshaderinc"

uniform sampler2D profile_tex : filter_nearest;
uniform int resolution = 256;
uniform int count = 8;
uniform float x_min = 0.0;
uniform float x_max = 4.0;
uniform bool slice_mode = false;
uniform float slice_u = 0.5;
uniform float slice_thickness = 0.03;
uniform vec4 color : source_color = vec4(0.95, 0.45, 0.2, 1.0);

vec4 profile(float u) {
	float x = clamp(u, 0.0, 1.0) * float(resolution - 1);
	int i = int(floor(x));
	vec4 a = texelFetch(profile_tex, ivec2(i, 0), 0);
	vec4 b = texelFetch(profile_tex, ivec2(min(i + 1, resolution - 1), 0), 0);
	return mix(a, b, x - float(i));
}

void vertex() {
	float u_mid;
	float x0;
	float x1;
	if (slice_mode) {
		u_mid = slice_u;
		float xc = mix(x_min, x_max, slice_u);
		x0 = xc - slice_thickness * 0.5;
		x1 = xc + slice_thickness * 0.5;
	} else {
		float w = 1.0 / float(count);
		u_mid = (float(INSTANCE_ID) + 0.5) * w;
		x0 = mix(x_min, x_max, float(INSTANCE_ID) * w);
		x1 = mix(x_min, x_max, float(INSTANCE_ID + 1) * w);
		// Small gap so neighbouring slabs read as separate pieces.
		float gap = (x1 - x0) * 0.04;
		x0 += gap;
		x1 -= gap;
	}
	vec4 pr = profile(u_mid);
	int part = int(round(UV2.x));
	float angle = UV.x * 6.2831853;
	vec2 dir = vec2(cos(angle), sin(angle));
	float radius = part == 0 ? pr.x : (part == 1 ? pr.y : mix(pr.y, pr.x, UV2.y));
	float x = mix(x0, x1, UV.y);
	vec3 n_m = part == 0 ? vec3(0.0, dir) : (part == 1 ? vec3(0.0, -dir) : vec3(UV.y < 0.5 ? -1.0 : 1.0, 0.0, 0.0));
	VERTEX = to_godot(vec3(x, radius * dir));
	NORMAL = to_godot(n_m);
}

void fragment() {
	ALBEDO = FRONT_FACING ? color.rgb : color.rgb * 0.6;
	ROUGHNESS = 0.45;
}
