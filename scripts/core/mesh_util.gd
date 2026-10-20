class_name MeshUtil
extends RefCounted
## Index meshes for the GPU-driven shaders. Their vertices mostly carry indices
## in UV/UV2; the vertex shaders read the real positions from data textures.

static var _font: SystemFont


## Unit arrow along +y: shaft (radius 1, UV.x = 0) and head (radius 2.4, UV.x = 1),
## each spanning y in [0, 1]; the arrow shader stretches them independently.
static func arrow_mesh(sides: int = 8) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in sides:
		var a0 := TAU * s / sides
		var a1 := TAU * (s + 1) / sides
		var c0 := Vector3(cos(a0), 0.0, sin(a0))
		var c1 := Vector3(cos(a1), 0.0, sin(a1))
		# Shaft side.
		_tri(st, [c0, c0 + Vector3.UP, c1 + Vector3.UP], [c0, c0, c1], 0.0)
		_tri(st, [c0, c1 + Vector3.UP, c1], [c0, c1, c1], 0.0)
		# Head: cone from radius 2.4 at y = 0 to the tip at y = 1.
		var h0 := c0 * 2.4
		var h1 := c1 * 2.4
		var n0 := Vector3(c0.x, 0.5, c0.z).normalized()
		var n1 := Vector3(c1.x, 0.5, c1.z).normalized()
		_tri(st, [h0, Vector3.UP, h1], [n0, (n0 + n1).normalized(), n1], 1.0)
		# Head base disc.
		_tri(st, [Vector3.ZERO, h0, h1], [Vector3.DOWN, Vector3.DOWN, Vector3.DOWN], 1.0)
	return st.commit()


static func _tri(st: SurfaceTool, verts: Array, normals: Array, part: float) -> void:
	# Counter-clockwise seen from outside is Godot's front face after the
	# winding flip below.
	for i in [0, 2, 1]:
		st.set_normal(normals[i])
		st.set_uv(Vector2(part, 0.0))
		st.add_vertex(verts[i])


## n × n grid whose UV = (i, j) / (n - 1); used for texture-driven surfaces.
static func grid_mesh(n: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	verts.resize(n * n)
	uvs.resize(n * n)
	normals.resize(n * n)
	for j in n:
		for i in n:
			var k := j * n + i
			uvs[k] = Vector2(i, j) / float(n - 1)
			verts[k] = Vector3(uvs[k].x, 0.0, uvs[k].y)
			normals[k] = Vector3.UP
	var indices := PackedInt32Array()
	indices.resize((n - 1) * (n - 1) * 6)
	var w := 0
	for j in n - 1:
		for i in n - 1:
			var a := j * n + i
			# Clockwise (Godot's front face) seen from the side r_u × r_v points to.
			for v in [a, a + n, a + 1, a + 1, a + n, a + n + 1]:
				indices[w] = v
				w += 1
	return _commit(verts, normals, uvs, PackedVector2Array(), indices)


## Ribbons for `seeds` field lines of `points` points: UV = (point, seed), UV2.x = side.
static func ribbon_mesh(points: int, seeds: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for s in seeds:
		var base := verts.size()
		for i in points:
			for side: float in [-1.0, 1.0]:
				verts.append(Vector3(i, s, side) * 0.001)
				uvs.append(Vector2(i, s))
				uv2s.append(Vector2(side, 0.0))
				normals.append(Vector3.UP)
		for i in points - 1:
			var a := base + i * 2
			indices.append_array([a, a + 2, a + 1, a + 1, a + 2, a + 3])
	return _commit(verts, normals, uvs, uv2s, indices)


## Solid of revolution parts (see revolution.gdshader): walls (u × angle),
## end caps (angle × radial), flat regions (u × radial).
static func revolution_mesh(u_steps: int, angle_steps: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var add_grid := func(part: int, nx: int, ny: int) -> void:
		var base := verts.size()
		for j in ny:
			for i in nx:
				var uv := Vector2(float(i) / (nx - 1), float(j) / (ny - 1))
				verts.append(Vector3(uv.x, uv.y, part) * 0.001)
				normals.append(Vector3.UP)
				if part == 2 or part == 3 or part == 4 or part == 5:
					# UV.y is the radial fraction for caps and regions.
					uvs.append(uv)
					uv2s.append(Vector2(part, uv.y))
				else:
					uvs.append(uv)
					uv2s.append(Vector2(part, 0.0))
		for j in ny - 1:
			for i in nx - 1:
				var a: int = base + j * nx + i
				indices.append_array([a, a + 1, a + nx, a + 1, a + nx + 1, a + nx])
	add_grid.call(0, u_steps, angle_steps)
	add_grid.call(1, u_steps, angle_steps)
	add_grid.call(2, angle_steps, 2)
	add_grid.call(3, angle_steps, 2)
	add_grid.call(4, u_steps, 2)
	add_grid.call(5, u_steps, 2)
	return _commit(verts, normals, uvs, uv2s, indices)


## One washer slab (see washers.gdshader): outer/inner walls and two faces.
static func washer_mesh(segments: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	# Walls: angle × (left, right).
	for part in [0, 1]:
		var base := verts.size()
		for j in 2:
			for i in segments + 1:
				verts.append(Vector3(i, j, part) * 0.001)
				uvs.append(Vector2(float(i) / segments, j))
				uv2s.append(Vector2(part, 0.0))
				normals.append(Vector3.UP)
		for i in segments:
			var a := base + i
			var b := a + segments + 1
			indices.append_array([a, a + 1, b, a + 1, b + 1, b])
	# Faces: angle × radial (inner, outer), at left (UV.y = 0) and right (1).
	for side in [0, 1]:
		var base := verts.size()
		for r in 2:
			for i in segments + 1:
				verts.append(Vector3(i, r, side + 2) * 0.001)
				uvs.append(Vector2(float(i) / segments, side))
				uv2s.append(Vector2(2.0, r))
				normals.append(Vector3.UP)
		for i in segments:
			var a := base + i
			var b := a + segments + 1
			indices.append_array([a, a + 1, b, a + 1, b + 1, b])
	return _commit(verts, normals, uvs, uv2s, indices)


static func _commit(verts: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array,
		uv2s: PackedVector2Array, indices: PackedInt32Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	if not uv2s.is_empty():
		arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## MultiMesh of `count` instances with identity transforms (the shader positions them).
static func identity_multimesh(mesh: Mesh, count: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = count
	if count > 0:
		var buffer := PackedFloat32Array()
		buffer.resize(count * 12)
		for i in count:
			var o := i * 12
			buffer[o] = 1.0
			buffer[o + 5] = 1.0
			buffer[o + 10] = 1.0
		mm.buffer = buffer
	return mm


## System font with good coverage of math symbols (∂ ∇ ∫ √ π ω).
static func math_font() -> Font:
	if _font == null:
		_font = SystemFont.new()
		_font.font_names = PackedStringArray(["Noto Sans", "DejaVu Sans", "Liberation Sans", "sans-serif"])
	return _font


## Billboard label readable on top of geometry.
static func label(text: String, font_size: int = 32, billboard := true) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = math_font()
	l.font_size = font_size
	l.pixel_size = 0.0012
	l.outline_size = 10
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED if billboard else BaseMaterial3D.BILLBOARD_DISABLED
	l.no_depth_test = billboard
	l.render_priority = 10
	return l


static func flat_material(color: Color, unshaded := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if color.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


## A plain arrow node (CPU-placed; for probes), pointing along `v` from its origin.
static func make_arrow(color: Color, radius := 0.012) -> Node3D:
	var root := Node3D.new()
	var mat := flat_material(color)
	var shaft := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = 1.0
	cyl.radial_segments = 10
	cyl.material = mat
	shaft.mesh = cyl
	shaft.name = "Shaft"
	var head := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = radius * 2.6
	cone.height = radius * 6.0
	cone.radial_segments = 10
	cone.material = mat
	head.mesh = cone
	head.name = "Head"
	root.add_child(shaft)
	root.add_child(head)
	root.set_meta("radius", radius)
	return root


## Points an arrow from make_arrow() along `v` (in its parent's space); hidden when tiny.
static func set_arrow(arrow: Node3D, v: Vector3) -> void:
	var length := v.length()
	arrow.visible = length > 1e-5
	if not arrow.visible:
		return
	var radius: float = arrow.get_meta("radius")
	var head_len := minf(radius * 6.0, length * 0.5)
	var shaft_len := length - head_len
	var y := v / length
	var ref := Vector3.RIGHT if absf(y.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var x := y.cross(ref).normalized()
	arrow.basis = Basis(x, y, x.cross(y))
	var shaft: MeshInstance3D = arrow.get_node("Shaft")
	var head: MeshInstance3D = arrow.get_node("Head")
	shaft.scale = Vector3(1.0, shaft_len, 1.0)
	shaft.position = Vector3(0.0, shaft_len * 0.5, 0.0)
	head.scale = Vector3.ONE * (head_len / (radius * 6.0))
	head.position = Vector3(0.0, shaft_len + head_len * 0.5, 0.0)


static func to_godot(m: Vector3) -> Vector3:
	return Vector3(m.x, m.z, -m.y)


static func to_math(g: Vector3) -> Vector3:
	return Vector3(g.x, -g.z, g.y)
