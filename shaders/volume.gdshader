// Ray-marched volume of div F or |curl F| from the compute shader's 3D texture.
// Drawn on the back faces of a [-1, 1]³ box (so it also works from inside);
// the box node is scaled by the domain half-size E.
// Local box coords l -> math (l.x, -l.z, l.y) -> texture uvw = math * 0.5 + 0.5.
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never, blend_mix;

#include "res://shaders/common.gdshaderinc"

uniform sampler3D volume_tex : filter_linear, repeat_disable;
uniform sampler2D stats_tex : filter_nearest;
// 0: div F (red sources, blue sinks); 1: |curl F|.
uniform int mode = 0;
uniform int steps = 64;
// Opacity per unit length at the max value (a uniform field gives a light haze).
uniform float density = 0.7;
// Values below this fraction of the max are transparent.
uniform float threshold = 0.08;

vec2 box_hit(vec3 ro, vec3 rd) {
	vec3 inv = 1.0 / rd;
	vec3 t0 = (vec3(-1.0) - ro) * inv;
	vec3 t1 = (vec3(1.0) - ro) * inv;
	vec3 tmin = min(t0, t1);
	vec3 tmax = max(t0, t1);
	return vec2(max(max(tmin.x, tmin.y), tmin.z), min(min(tmax.x, tmax.y), tmax.z));
}

void fragment() {
	mat4 to_local = inverse(MODEL_MATRIX) * INV_VIEW_MATRIX;
	vec3 ro = (to_local * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 rd = normalize((to_local * vec4(normalize(VERTEX), 0.0)).xyz);
	vec2 hit = box_hit(ro, rd);
	float t_start = max(hit.x, 0.0);
	float t_end = hit.y;
	vec4 stats = texelFetch(stats_tex, ivec2(0, 0), 0);
	float top = max(mode == 0 ? stats.y : stats.z, 1e-6);
	float dt = 3.4641 / float(steps);  // box diagonal / steps
	vec4 acc = vec4(0.0);
	float t = t_start + dt * 0.5;
	for (int i = 0; i < steps; i++) {
		if (t > t_end || acc.a > 0.97) break;
		vec3 l = ro + rd * t;
		vec3 uvw = vec3(l.x, -l.z, l.y) * 0.5 + 0.5;
		vec4 v = texture(volume_tex, uvw);
		float s = mode == 0 ? v.x / top : length(v.yzw) / top;
		float a = smoothstep(threshold, 1.0, abs(s)) * density * dt;
		vec3 col = mode == 0 ? diverging(sign(s) * max(abs(s), 0.35)) : turbo(abs(s));
		acc.rgb += (1.0 - acc.a) * a * col;
		acc.a += (1.0 - acc.a) * a;
		t += dt;
	}
	ALBEDO = acc.a > 0.0 ? acc.rgb / acc.a : vec3(0.0);
	ALPHA = clamp(acc.a, 0.0, 1.0);
}
