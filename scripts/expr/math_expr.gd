class_name MathExpr
extends RefCounted
## A user-typed math expression such as "x^2 - y^2" or "-y + a sin(t)".
## A recursive-descent parser builds an AST that is emitted two ways:
##  * to_glsl(): GLSL source, compiled into the GPU compute shaders;
##  * evaluate(): a Godot Expression, used by the CPU baseline and the probes.
## Both come from the same AST, so the GPU and the CPU compute the same function.
## Adds what plain syntax lacks: ^ for powers, implicit multiplication
## (2x, x y, 3sin(x)), ln, pi and e.

## Name -> [GDScript function, GLSL function, argument count].
const FUNCTIONS := {
	"sin": ["sin", "sin", 1], "cos": ["cos", "cos", 1], "tan": ["tan", "tan", 1],
	"asin": ["asin", "asin", 1], "acos": ["acos", "acos", 1], "atan": ["atan", "atan", 1],
	"arcsin": ["asin", "asin", 1], "arccos": ["acos", "acos", 1], "arctan": ["atan", "atan", 1],
	"sinh": ["sinh", "sinh", 1], "cosh": ["cosh", "cosh", 1], "tanh": ["tanh", "tanh", 1],
	"sqrt": ["sqrt", "sqrt", 1], "exp": ["exp", "exp", 1], "ln": ["log", "log", 1],
	"log": ["log", "log", 1], "abs": ["absf", "abs", 1], "floor": ["floor", "floor", 1],
	"ceil": ["ceil", "ceil", 1], "sign": ["signf", "sign", 1],
	"min": ["minf", "min", 2], "max": ["maxf", "max", 2], "atan2": ["atan2", "atan", 2],
}
const CONSTANTS := {"pi": PI, "π": PI, "e": 2.718281828459045, "tau": TAU}

var text := ""
var variables: PackedStringArray
var error := ""
## Parsed tree: ["num", v] | ["var", name] | ["neg", a] | ["bin", op, a, b]
## | ["pow", a, b] | ["call", name, [args]].
var ast: Array = []

var _expression := Expression.new()
var _tokens: Array[String] = []
var _pos := 0


static func compile(source: String, vars: PackedStringArray) -> MathExpr:
	var expr := MathExpr.new()
	expr.text = source.strip_edges()
	expr.variables = vars
	expr._compile()
	return expr


## Compiles "(a, b, c)" into one MathExpr per component. Returns
## {"exprs": Array[MathExpr], "error": String}.
static func compile_tuple(source: String, vars: PackedStringArray, count: int) -> Dictionary:
	var parts := split_tuple(source)
	var exprs: Array[MathExpr] = []
	if parts.size() != count:
		return {"exprs": exprs, "error": "Need %d components separated by commas, like (−y, x, 0)" % count}
	for i in count:
		var expr := compile(parts[i], vars)
		if not expr.is_valid():
			return {"exprs": exprs, "error": "Component %d: %s" % [i + 1, expr.error]}
		exprs.append(expr)
	return {"exprs": exprs, "error": ""}


## Splits "(a, b, c)" or "a, b, c" at top-level commas (not those inside max(x, y)).
static func split_tuple(source: String) -> PackedStringArray:
	var s := source.strip_edges()
	if s.begins_with("(") and s.ends_with(")"):
		var depth := 0
		var encloses := true
		for i in s.length():
			depth += 1 if s[i] == "(" else (-1 if s[i] == ")" else 0)
			if depth == 0 and i < s.length() - 1:
				encloses = false
				break
		if encloses:
			s = s.substr(1, s.length() - 2)
	var parts := PackedStringArray()
	var depth := 0
	var start := 0
	for i in s.length():
		if s[i] == "(":
			depth += 1
		elif s[i] == ")":
			depth -= 1
		elif s[i] == "," and depth == 0:
			parts.append(s.substr(start, i - start).strip_edges())
			start = i + 1
	parts.append(s.substr(start).strip_edges())
	return parts


func is_valid() -> bool:
	return error.is_empty()


## True if the expression mentions `name` (e.g. "t": the field changes over time).
func uses(name: String) -> bool:
	return _uses(ast, name)


## Evaluates with values in the same order as `variables`. Returns NAN on failure.
func evaluate(values: Array) -> float:
	var result: Variant = _expression.execute(values, null, false)
	if _expression.has_execute_failed() or not (result is float or result is int):
		return NAN
	return float(result)


## GLSL source of this expression. `names` maps a variable to its GLSL spelling
## (e.g. {"t": "T"}); unmapped variables keep their name.
func to_glsl(names: Dictionary = {}) -> String:
	return _glsl(ast, names)


## Godot Expression source (for debugging and the CPU path).
func to_gd() -> String:
	return _gd(ast)


func _compile() -> void:
	if text.is_empty():
		error = "Type a function first"
		return
	if not _tokenize():
		return
	_pos = 0
	ast = _parse_sum()
	if error.is_empty() and _pos < _tokens.size():
		error = "Unexpected '%s'" % _tokens[_pos]
	if not error.is_empty():
		return
	if _expression.parse(_gd(ast), variables) != OK:
		error = _expression.get_error_text()
		return
	var probe := []
	for v in variables:
		probe.append(0.5)
	_expression.execute(probe, null, false)
	if _expression.has_execute_failed():
		error = _expression.get_error_text()


# --- Emitters ---------------------------------------------------------------

static func _float_literal(v: float) -> String:
	var s := str(v)  # shortest round-trip form, e.g. "3.0", "0.001", "1e-12"
	if not ("." in s or "e" in s):
		s += ".0"
	return s


func _gd(node: Array) -> String:
	match node[0]:
		"num":
			return _float_literal(node[1])
		"var":
			return node[1]
		"neg":
			return "(-%s)" % _gd(node[1])
		"bin":
			return "(%s %s %s)" % [_gd(node[2]), node[1], _gd(node[3])]
		"pow":
			return "pow(%s, %s)" % [_gd(node[1]), _gd(node[2])]
		"call":
			var args := PackedStringArray()
			for a: Array in node[2]:
				args.append(_gd(a))
			return "%s(%s)" % [FUNCTIONS[node[1]][0], ", ".join(args)]
	return "0.0"


func _glsl(node: Array, names: Dictionary) -> String:
	match node[0]:
		"num":
			return _float_literal(node[1])
		"var":
			return names.get(node[1], node[1])
		"neg":
			return "(-%s)" % _glsl(node[1], names)
		"bin":
			return "(%s %s %s)" % [_glsl(node[2], names), node[1], _glsl(node[3], names)]
		"pow":
			# GLSL pow() is undefined for negative bases; p_pow handles (-2)^3 = -8.
			var exponent: Array = node[2]
			if exponent[0] == "num" and exponent[1] == 2.0:
				var b := _glsl(node[1], names)
				return "sq(%s)" % b
			return "p_pow(%s, %s)" % [_glsl(node[1], names), _glsl(exponent, names)]
		"call":
			var args := PackedStringArray()
			for a: Array in node[2]:
				args.append(_glsl(a, names))
			return "%s(%s)" % [FUNCTIONS[node[1]][1], ", ".join(args)]
	return "0.0"


func _uses(node: Array, name: String) -> bool:
	match node[0]:
		"var":
			return node[1] == name
		"neg":
			return _uses(node[1], name)
		"bin":
			return _uses(node[2], name) or _uses(node[3], name)
		"pow":
			return _uses(node[1], name) or _uses(node[2], name)
		"call":
			for a: Array in node[2]:
				if _uses(a, name):
					return true
	return false


# --- Tokenizer and parser ---------------------------------------------------------

func _tokenize() -> bool:
	var s := text.replace("**", "^").replace("·", "*").replace("×", "*").replace("−", "-")
	var i := 0
	while i < s.length():
		var c := s[i]
		if c == " " or c == "\t":
			i += 1
		elif c.is_valid_int() or c == ".":
			var start := i
			while i < s.length() and (s[i].is_valid_int() or s[i] == "."):
				i += 1
			# Scientific notation like 1e-3, but not "2e" meaning 2·e.
			if i + 1 < s.length() and s[i] == "e" and (s[i + 1].is_valid_int()
					or (s[i + 1] in "+-" and i + 2 < s.length() and s[i + 2].is_valid_int())):
				i += 2
				while i < s.length() and s[i].is_valid_int():
					i += 1
			var number := s.substr(start, i - start)
			if not number.is_valid_float():
				error = "Bad number '%s'" % number
				return false
			_tokens.append(number)
		elif _is_letter(c):
			var start := i
			while i < s.length() and (_is_letter(s[i]) or s[i].is_valid_int()):
				i += 1
			_split_word(s.substr(start, i - start))
		elif c in "+-*/^(),":
			_tokens.append(c)
			i += 1
		else:
			error = "Unexpected character '%s'" % c
			return false
	return true


## Splits glued names like "xy" or "xsin" into known pieces (x, y, sin).
func _split_word(word: String) -> void:
	if FUNCTIONS.has(word) or CONSTANTS.has(word) or variables.has(word):
		_tokens.append(word)
		return
	var i := 0
	while i < word.length():
		var best := ""
		for name: String in FUNCTIONS.keys() + CONSTANTS.keys() + Array(variables):
			if word.substr(i).begins_with(name) and name.length() > best.length():
				best = name
		if best.is_empty():
			best = word[i]
		_tokens.append(best)
		i += best.length()


static func _is_letter(c: String) -> bool:
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_" or c == "π"


func _peek() -> String:
	return _tokens[_pos] if _pos < _tokens.size() else ""


func _expect(token: String) -> void:
	if _peek() == token:
		_pos += 1
	elif error.is_empty():
		error = "Missing '%s'" % token if _peek().is_empty() else "Expected '%s' but found '%s'" % [token, _peek()]


## sum := product (('+' | '-') product)*
func _parse_sum() -> Array:
	var out := _parse_product()
	while error.is_empty() and _peek() in ["+", "-"]:
		var op := _peek()
		_pos += 1
		out = ["bin", op, out, _parse_product()]
	return out


## product := unary (('*' | '/' | implicit) unary)*
func _parse_product() -> Array:
	var out := _parse_unary()
	while error.is_empty():
		var t := _peek()
		if t == "*" or t == "/":
			_pos += 1
			out = ["bin", t, out, _parse_unary()]
		elif _starts_factor(t):
			out = ["bin", "*", out, _parse_unary()]
		else:
			break
	return out


## unary := '-' unary | power   (so -x^2 = -(x^2))
func _parse_unary() -> Array:
	if _peek() == "-":
		_pos += 1
		return ["neg", _parse_unary()]
	if _peek() == "+":
		_pos += 1
		return _parse_unary()
	return _parse_power()


## power := atom ('^' unary)?   (right-associative)
func _parse_power() -> Array:
	var base := _parse_atom()
	if error.is_empty() and _peek() == "^":
		_pos += 1
		return ["pow", base, _parse_unary()]
	return base


func _parse_atom() -> Array:
	var t := _peek()
	if t.is_empty():
		if error.is_empty():
			error = "Expression ends too early"
		return ["num", 0.0]
	_pos += 1
	if t == "(":
		var inner := _parse_sum()
		_expect(")")
		return inner
	if t.is_valid_float():
		return ["num", t.to_float()]
	if variables.has(t):
		return ["var", t]
	if CONSTANTS.has(t):
		return ["num", CONSTANTS[t]]
	if FUNCTIONS.has(t):
		var count: int = FUNCTIONS[t][2]
		var args: Array = []
		if _peek() == "(":
			_pos += 1
			args.append(_parse_sum())
			while error.is_empty() and _peek() == ",":
				_pos += 1
				args.append(_parse_sum())
			_expect(")")
		elif count == 1:
			# sin x, sin 2x: an argument without brackets binds to one power term.
			args.append(_parse_power())
		if error.is_empty() and args.size() != count:
			error = "%s needs %d argument%s" % [t, count, "" if count == 1 else "s"]
		return ["call", t, args]
	if error.is_empty():
		if _is_letter(t[0]):
			error = "Unknown name '%s' (use %s)" % [t, ", ".join(variables)]
		else:
			error = "Unexpected '%s'" % t
	return ["num", 0.0]


func _starts_factor(t: String) -> bool:
	return t == "(" or t.is_valid_float() or variables.has(t) or CONSTANTS.has(t) \
			or FUNCTIONS.has(t)
