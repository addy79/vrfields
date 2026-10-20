// Dark floor with a fading 0.5 m grid (gives scale and grounding in VR).
shader_type spatial;
render_mode unshaded;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 g = v_world.xz / 0.5;
	vec2 d = abs(fract(g - 0.5) - 0.5) / fwidth(g);
	float line = 1.0 - min(min(d.x, d.y), 1.0);
	float fade = exp(-length(v_world.xz) * 0.12);
	ALBEDO = mix(vec3(0.035, 0.04, 0.055), vec3(0.25, 0.32, 0.45), line * fade);
}
