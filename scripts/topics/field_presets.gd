class_name FieldPresets
extends RefCounted
## Vector fields used by the Vector Field and Divergence & Curl topics.
## "note" is the idea the preset is meant to show (exact values in brackets).

const LIST: Array[Dictionary] = [
	{"name": "Rotation", "text": "(-y, x, 0)",
		"note": "Pure rotation: div F = 0 (no sources), curl F = (0, 0, 2) everywhere,\nso a paddle wheel spins at ω = ½|curl F| = 1 rad/s anywhere, even off-centre."},
	{"name": "Source", "text": "(x, y, z)",
		"note": "Radial source: div F = 3 everywhere, curl F = 0.\nFlux out of any small sphere ≈ div F × volume."},
	{"name": "Sink", "text": "(-x, -y, -z)",
		"note": "Radial sink: div F = −3 everywhere (particles pile up at the origin), curl F = 0."},
	{"name": "Saddle", "text": "(x, -y, 0)",
		"note": "Saddle flow: stretches along x, squeezes along y.\ndiv F = 0 and curl F = 0: area is preserved and nothing rotates."},
	{"name": "Shear", "text": "(y, 0, 0)",
		"note": "Shear: the flow lines are straight, yet curl F = (0, 0, −1).\nA paddle wheel still turns: curl is local spin, not curved paths."},
	{"name": "Vortex in a sink", "text": "(-y - 0.3x, x - 0.3y, 0)",
		"note": "Spiral: rotation plus inflow. div F = −0.6, curl F = (0, 0, 2)."},
	{"name": "Helix", "text": "(-y, x, a)",
		"note": "Rotation plus a constant lift a (slider): field lines are helices.\ndiv F = 0, curl F = (0, 0, 2) whatever a is."},
	{"name": "Gradient of xyz", "text": "(y z, x z, x y)",
		"note": "F = ∇(xyz) is a gradient field, so curl F = 0 exactly (conservative).\ndiv F = 0 too: xyz is harmonic."},
	{"name": "Point charge", "text": "(x / (x^2 + y^2 + z^2 + 0.05)^1.5, y / (x^2 + y^2 + z^2 + 0.05)^1.5, z / (x^2 + y^2 + z^2 + 0.05)^1.5)",
		"note": "Softened inverse-square field. With no softening div F would be 0 away\nfrom the origin; here the source is spread over a small ball (div > 0 near 0)."},
	{"name": "ABC flow", "text": "(sin(z) + cos(y), sin(x) + cos(z), sin(y) + cos(x))",
		"note": "Arnold–Beltrami–Childress flow: divergence-free (div F = 0) and\ncurl F = F (a Beltrami field). Particles wander chaotically."},
	{"name": "Breathing vortex (t)", "text": "(-y + x sin(t), x + y sin(t), 0)",
		"note": "Time-dependent: curl F = (0, 0, 2) stays fixed while div F = 2 sin t\nswings between source and sink. The GPU recomputes it every frame."},
	{"name": "Travelling wave (t)", "text": "(-a y / 2, a x / 2, sin(2x - 2t))",
		"note": "A wave moving along x (curl F = (0, −2cos(2x − 2t), 0) + a ẑ).\nSlide a to add rotation."},
]
