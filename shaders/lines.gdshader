// Field lines (streamlines) traced by the compute shader, drawn as camera-facing
// ribbons. Mesh vertices carry indices only: UV = (point index, seed index),
// UV2.x = side (-1 or +1). Data: "lines" texture, (2L+1) × S, texel = (point, |F|/max).
shader_type spatial;
render_mode unshaded, cull_disabled;

#include "res://shaders/common.gdshaderinc"

uniform sampler2D line_tex : filter_nearest;
uniform int points = 193;
uniform float width = 0.012;

varying vec3 v_color;

void vertex() {
	int i = int(round(UV.x));
	int s = int(round(UV.y));
	vec4 p = texelFetch(line_tex, ivec2(i, s), 0);
	vec4 prev = texelFetch(line_tex, ivec2(max(i - 1, 0), s), 0);
	vec4 next = texelFetch(line_tex, ivec2(min(i + 1, points - 1), s), 0);
	vec3 c = (MODELVIEW_MATRIX * vec4(to_godot(p.xyz), 1.0)).xyz;
	vec3 tangent = (MODELVIEW_MATRIX * vec4(to_godot(next.xyz - prev.xyz), 0.0)).xyz;
	vec3 side = cross(tangent, normalize(-c));
	side = length(side) > 1e-9 ? normalize(side) : vec3(0.0);
	POSITION = PROJECTION_MATRIX * vec4(c + side * UV2.x * width, 1.0);
	v_color = mix(vec3(1.0), turbo(p.w), 0.75);
}

void fragment() {
	ALBEDO = v_color;
}
