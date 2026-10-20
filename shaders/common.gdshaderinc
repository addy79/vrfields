// Shared helpers for the visual shaders.
// Math coordinates are z-up; Godot is y-up: (x, y, z)_math -> (x, z, -y)_godot.

vec3 to_godot(vec3 m) {
	return vec3(m.x, m.z, -m.y);
}

// Turbo colormap (Mikhailov 2019, polynomial fit), t in [0, 1]: blue -> green -> red.
vec3 turbo(float t) {
	t = clamp(t, 0.0, 1.0);
	const vec4 kr4 = vec4(0.13572138, 4.61539260, -42.66032258, 132.13108234);
	const vec4 kg4 = vec4(0.09140261, 2.19418839, 4.84296658, -14.18503333);
	const vec4 kb4 = vec4(0.10667330, 12.64194608, -60.58204836, 110.36276771);
	const vec2 kr2 = vec2(-152.94239396, 59.28637943);
	const vec2 kg2 = vec2(4.27729857, 2.82956604);
	const vec2 kb2 = vec2(-89.90310912, 27.34824973);
	vec4 v4 = vec4(1.0, t, t * t, t * t * t);
	vec2 v2 = v4.zw * v4.z;
	return vec3(dot(v4, kr4) + dot(v2, kr2), dot(v4, kg4) + dot(v2, kg2), dot(v4, kb4) + dot(v2, kb2));
}

// Diverging blue (s = -1) -> near-white (0) -> red (+1), for signed quantities
// such as div F (sinks blue, sources red) or curvature.
vec3 diverging(float s) {
	s = clamp(s, -1.0, 1.0);
	vec3 mid = vec3(0.92, 0.92, 0.9);
	vec3 neg = vec3(0.13, 0.35, 0.95);
	vec3 pos = vec3(0.95, 0.2, 0.12);
	return s < 0.0 ? mix(mid, neg, -s) : mix(mid, pos, s);
}

// Orthonormal frame (b1, d, b2) around unit direction d.
mat3 frame_from_dir(vec3 d) {
	vec3 ref = abs(d.y) > 0.99 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
	vec3 b1 = normalize(cross(d, ref));
	vec3 b2 = cross(b1, d);
	return mat3(b1, d, b2);
}
