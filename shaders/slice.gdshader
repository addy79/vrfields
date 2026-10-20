// A movable slicing plane that colours each point by div F, the curl component
// through the plane (circulation density), or |curl F|, sampled from the
// compute shader's 3D texture. world_to_volume maps world space into the
// volume box's local [-1, 1]³ (set every frame by the script).
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_opaque;

#include "res://shaders/common.gdshaderinc"

uniform sampler3D volume_tex : filter_linear, repeat_disable;
uniform sampler2D stats_tex : filter_nearest;
uniform mat4 world_to_volume;
// 0: div F; 1: (curl F)·n; 2: |curl F|.
uniform int mode = 0;
// Plane normal in math coordinates (for mode 1).
uniform vec3 normal_math = vec3(0.0, 0.0, 1.0);
uniform float opacity = 0.88;
uniform float contours = 10.0;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 l = (world_to_volume * vec4(v_world, 1.0)).xyz;
	if (any(greaterThan(abs(l), vec3(1.0)))) discard;
	vec3 uvw = vec3(l.x, -l.z, l.y) * 0.5 + 0.5;
	vec4 v = texture(volume_tex, uvw);
	vec4 stats = texelFetch(stats_tex, ivec2(0, 0), 0);
	float s;
	vec3 col;
	if (mode == 0) {
		s = v.x / max(stats.y, 1e-6);
		col = diverging(s);
	} else if (mode == 1) {
		s = dot(v.yzw, normalize(normal_math)) / max(stats.z, 1e-6);
		col = diverging(s);
	} else {
		s = length(v.yzw) / max(stats.z, 1e-6);
		col = turbo(s);
	}
	// Contour lines every 1/contours of the max, anti-aliased with fwidth.
	float c = s * contours;
	float line = 1.0 - smoothstep(0.0, 1.5 * fwidth(c), abs(fract(c + 0.5) - 0.5));
	col = mix(col, col * 0.35, line * 0.6);
	ALBEDO = col;
	ALPHA = opacity;
}
