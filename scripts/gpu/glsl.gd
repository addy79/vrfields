class_name Glsl
extends RefCounted
## GLSL building blocks shared by every compute shader. A shader is assembled as
##   HEADER + "#define PASS_X" + generated user functions + kernel body
## and compiled at runtime (RenderingDevice.shader_compile_spirv_from_source).

## Push constants: 8 vec4 = 128 bytes, the size Vulkan guarantees everywhere.
## Kernels name the slots with #defines (e.g. #define T pc.p[0].x).
const PUSH_SIZE := 128

const HEADER := """#version 450
layout(push_constant, std430) uniform Params { vec4 p[8]; } pc;

#define NAN_F uintBitsToFloat(0x7fc00000u)
// Time and the two user parameters, available to every user function.
float T;
float PA;
float PB;

float sq(float x) { return x * x; }

// pow() for negative bases with whole exponents: (-2)^3 = -8, like the CPU path.
float p_pow(float x, float y) {
	if (x > 0.0) return pow(x, y);
	if (x == 0.0) return y > 0.0 ? 0.0 : (y == 0.0 ? 1.0 : NAN_F);
	float r = round(y);
	if (abs(y - r) > 1e-6) return NAN_F;
	float m = pow(-x, y);
	return mod(r, 2.0) == 0.0 ? m : -m;
}

// NaN/inf test on the bits, so fast-math drivers cannot optimise it away.
bool bad(float v) { return (floatBitsToUint(v) & 0x7f800000u) == 0x7f800000u; }
float fin(float v) { return bad(v) ? 0.0 : v; }
vec3 fin3(vec3 v) { return vec3(fin(v.x), fin(v.y), fin(v.z)); }

// Order-preserving float <-> uint mapping, so atomicMin/atomicMax work on floats.
uint ord(float v) {
	uint u = floatBitsToUint(v);
	return (u & 0x80000000u) != 0u ? ~u : (u | 0x80000000u);
}
float unord(uint u) {
	return uintBitsToFloat((u & 0x80000000u) != 0u ? (u & 0x7fffffffu) : ~u);
}

// PCG hash: per-particle random numbers without any CPU involvement.
uint pcg(uint v) {
	uint state = v * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}
float rand01(inout uint s) { s = pcg(s); return float(s) / 4294967295.0; }

void load_common() { T = pc.p[0].x; PA = pc.p[0].y; PB = pc.p[0].z; }
"""

## Variable names in user expressions -> GLSL spelling.
const NAMES := {"t": "T", "a": "PA", "b": "PB"}


## "float NAME(float x, float y) { return <expr>; }"
static func scalar_function(fn_name: String, args: PackedStringArray, expr: MathExpr) -> String:
	return "float %s(%s) { return %s; }\n" % [fn_name, _arg_list(args), expr.to_glsl(NAMES)]


## "vec3 NAME(float x, ...) { return vec3(<e0>, <e1>, <e2>); }"
static func vec3_function(fn_name: String, args: PackedStringArray, exprs: Array[MathExpr]) -> String:
	return "vec3 %s(%s) { return vec3(%s, %s, %s); }\n" % [fn_name, _arg_list(args),
			exprs[0].to_glsl(NAMES), exprs[1].to_glsl(NAMES), exprs[2].to_glsl(NAMES)]


static func _arg_list(args: PackedStringArray) -> String:
	var parts := PackedStringArray()
	for a in args:
		parts.append("float " + a)
	return ", ".join(parts)


## Packs up to 32 floats into the 128-byte push-constant block.
static func push(values: PackedFloat32Array) -> PackedByteArray:
	var padded := values.duplicate()
	padded.resize(PUSH_SIZE / 4)
	return padded.to_byte_array()
