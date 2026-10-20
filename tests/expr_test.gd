extends SceneTree
## Expression compiler test (no GPU needed):
##   godot --headless --path . -s tests/expr_test.gd
## Checks parsing, CPU evaluation and the generated GLSL text.

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
	print("%s  %s" % ["ok  " if ok else "FAIL", what])


func _init() -> void:
	var xy := PackedStringArray(["x", "y"])
	var cases := [
		["x^2 - y^2", 2.0, 1.0, 3.0], ["2x sin(y)", 1.5, PI / 2, 3.0], ["xy", 2.0, 3.0, 6.0],
		["-x^2", 3.0, 0.0, -9.0], ["2^-1", 0.0, 0.0, 0.5], ["e^(-(x^2+y^2))", 0.0, 0.0, 1.0],
		["ln(e)", 0.0, 0.0, 1.0], ["sqrt(x)", 4.0, 0.0, 2.0], ["3(x+1)(y-1)", 1.0, 2.0, 6.0],
		["sin x cos y", PI / 2, 0.0, 1.0], ["2pi", 0.0, 0.0, TAU], ["abs(x) + max(x, y)", -2.0, 1.0, 3.0],
		["x**3", -2.0, 0.0, -8.0], ["1e-3*x", 1000.0, 0.0, 1.0], ["2e", 0.0, 0.0, 2.0 * exp(1.0)],
		["2^3^2", 0.0, 0.0, 512.0], ["atan2(y, x)", 1.0, 1.0, PI / 4], ["x / y / 2", 8.0, 2.0, 2.0],
	]
	for c in cases:
		var e := MathExpr.compile(c[0], xy)
		var v := e.evaluate([c[1], c[2]]) if e.is_valid() else NAN
		check(e.is_valid() and is_equal_approx(v, c[3]), "%-20s = %s  (expected %s)  GLSL: %s" % [c[0], v, c[3], e.to_glsl()])
	for bad in ["", "x +", "(x", "z^2", "sin()", "2 $ x", "max(x)", "x y)"]:
		var e := MathExpr.compile(bad, xy)
		check(not e.is_valid(), "rejects %-10s -> %s" % ["'" + bad + "'", e.error])

	# GLSL emission details.
	var g := MathExpr.compile("x^2 + y^3 + t", PackedStringArray(["x", "y", "t"]))
	var glsl := g.to_glsl(Glsl.NAMES)
	check("sq(x)" in glsl and "p_pow(y, 3.0)" in glsl and "T" in glsl, "GLSL squares, safe powers, t -> T: " + glsl)
	check(MathExpr.compile("atan2(y, x)", xy).to_glsl() == "atan(y, x)", "atan2 -> GLSL atan(y, x)")
	check(MathExpr.compile("ln(x)", xy).to_glsl() == "log(x)", "ln -> GLSL log")
	check(g.uses("t") and not MathExpr.compile("x", xy).uses("t"), "detects time dependence")

	var vec := MathExpr.compile_tuple("(-y, x*max(x, 1), 0)", PackedStringArray(["x", "y", "z"]), 3)
	check(vec.error.is_empty() and is_equal_approx(vec.exprs[1].evaluate([2.0, 0.0, 0.0]), 4.0), "tuple with a nested comma")
	for bad in ["(x, y)", "(x, y, q)"]:
		var r := MathExpr.compile_tuple(bad, PackedStringArray(["x", "y", "z"]), 3)
		check(not r.error.is_empty(), "tuple rejects %s -> %s" % [bad, r.error])

	# Input formats with ranges.
	var p := ParametricTopic.parse_input("(cos(u), sin(u), v), u = 0..2pi, v = -1..1")
	check(p.error.is_empty() and is_equal_approx(p.u.y, TAU) and is_equal_approx(p.v.x, -1.0), "parametric ranges parsed")
	var r := RevolutionTopic.parse_input("sqrt(x), x/2, x = 0..4")
	check(r.error.is_empty() and r.outer == "sqrt(x)" and r.inner == "x/2" and is_equal_approx(r.range.y, 4.0), "revolution washer input parsed")
	check(not RevolutionTopic.parse_input("sqrt(x), x = 0-4").error.is_empty(), "bad range reported")

	# Every preset compiles.
	for preset: Dictionary in FieldPresets.LIST:
		check(VectorFieldEngine.compile_text(preset.text).error.is_empty(), "field preset compiles: " + preset.name)
	for preset: Dictionary in GradientTopic.PRESETS:
		check(ScalarSurfaceEngine.compile_text(preset.text).is_valid(), "surface preset compiles: " + preset.name)
	for preset: Dictionary in RevolutionTopic.PRESETS:
		check(RevolutionTopic.parse_input(preset.text).error.is_empty(), "solid preset parses: " + preset.name)
	for preset: Dictionary in ParametricTopic.PRESETS:
		check(ParametricTopic.parse_input(preset.text).error.is_empty(), "surface preset parses: " + preset.name)

	print("expr_test: %d failures" % fails)
	quit(fails)
