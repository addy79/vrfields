// Flow particles advected by the compute shader. Each instance is a quad
// stretched into a streak along the local velocity, built in view space so it
// works per eye in VR. Data: "particles" texture, 256 wide, rows 0..R-1 hold
// (position, age), rows R..2R-1 hold (F, |F| / max).
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

#include "res://shaders/common.gdshaderinc"

uniform sampler2D particle_tex : filter_nearest;
uniform int rows = 16;
// Model units -> metres (the plot node's scale), so widths stay in metres.
uniform float world_scale = 0.35;
uniform float width = 0.012;
uniform float streak = 0.06;
uniform float opacity = 0.9;

varying vec4 v_color;
varying vec2 v_uv;

void vertex() {
	int id = INSTANCE_ID;
	ivec2 at = ivec2(id % 256, id / 256);
	vec4 pa = texelFetch(particle_tex, at, 0);
	vec4 vel = texelFetch(particle_tex, at + ivec2(0, rows), 0);
	vec3 center = (MODELVIEW_MATRIX * vec4(to_godot(pa.xyz), 1.0)).xyz;
	vec3 dir = (MODELVIEW_MATRIX * vec4(to_godot(vel.xyz), 0.0)).xyz;
	float dlen = length(dir);
	dir = dlen > 1e-9 ? dir / dlen : vec3(0.0, 1.0, 0.0);
	vec3 side = cross(dir, normalize(-center));
	side = length(side) > 1e-6 ? normalize(side) : vec3(1.0, 0.0, 0.0);
	float speed = clamp(vel.w, 0.0, 1.0);
	float alive = pa.w > 0.0 ? 1.0 : 0.0;
	float len = (width + streak * speed) * alive;
	vec3 pos = center + side * VERTEX.x * width * alive + dir * VERTEX.y * len;
	POSITION = PROJECTION_MATRIX * vec4(pos, 1.0);
	// Fade in the last second of life.
	v_color = vec4(turbo(speed), opacity * clamp(pa.w, 0.0, 1.0));
	v_uv = VERTEX.xy * 2.0;
}

void fragment() {
	float edge = 1.0 - smoothstep(0.6, 1.0, abs(v_uv.x));
	ALBEDO = v_color.rgb;
	ALPHA = v_color.a * edge;
}
