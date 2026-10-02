@tool
class_name ModelBaker extends RefCounted
## 节点图烘焙器 —— 把一张 [ModelGraph] 烘成 [PropBuild]，**一次烘焙出双产物**
##
## ============================ 它解决什么 ============================
## [method PropGenTool.bake] 只能从"一个手写 build() 的 PropGen 实例"出发，
## 而且只产出低多边形网格。这里补上两件事：
## · **输入**换成节点图 —— 配方可复用、可参数化、可换风格不重搭；
## · **输出**扩成双产物 —— 低多边形网格（[SdfMesh]）与体素网格（[SdfVoxel]）
##   **共用同一次场烘焙**。这是"一份数据两种用途"成立的成本前提：
##   烘焙（实测占总耗时 99.9% 以上，见 SDF/Readme.md 性能小节）只做一次，
##   两个提取步骤相对它都很便宜。
##
## ============================ 职责划分：图管结构，风格管质感 ============================
## · [ModelGraph] 决定**有什么部件、怎么组合**（屋顶、门窗、烟囱…）
## · [ToonStyleDef] 决定**多硬、多光滑、多薄壳**（画风）
##
## 所以同一张图换风格即可得到不同质感的模型，而结构不变。
## 若你希望连质感也由图控制（图里已有 [ModelHardenNode] / [ModelShellNode]），
## 传 `"style_geometry": false` 关掉本层的场级几何调整，避免重复施加。
##
## == 典型用法 ==
## [codeblock]
## var b := ModelBaker.bake(graph, 1234, {
##     "style": ToonStyleDef.presets()[&"anime_clean"],
##     "palette": ToonPaletteDef.presets()[&"anime_daylight"],
##     "voxel_res": 64,
## })
## print(b.triangle_count(), " 三角面 / ", b.voxel.count_solid(), " 体素")
## [/codeblock]

# ================================================================== 主入口

## 烘焙一张图。[param opt] 见下方键表。
##
## [codeblock]
## "voxel_size"     float  场体素边长；<=0 时取 style.voxel_size，再退化为 0.12
## "margin"         float  场边界余量；<0 时按体素的 3 倍
## "algo"           int    MeshExtractor.Algo；默认 DUAL_CONTOURING（保棱角，三渲二首选）
## "voxel_res"      int    体素输出最长边；<=0 跳过体素产物
## "style"          ToonStyleDef   可空
## "palette"        ToonPaletteDef 可空
## "style_geometry" bool   是否由风格施加场级几何调整；默认 true
## "voxel_slots"    bool   是否把材质槽位写进体素调色板；默认 true
## "emit_slot_uv"   bool   网格是否输出槽位 UV（换色免重算）；默认 true
## "pivot"          int    ModelGraph.Pivot；<0 时沿用图自身的设置
## "footprint"      Vector2 覆盖逻辑占地；不给则由网格 XZ 外接推算
## "meta"           Dictionary 附加元信息
## [/codeblock]
static func bake(g: ModelGraph, p_seed: int, opt := {}) -> PropBuild:
	if g == null or g.size() == 0:
		push_warning("[ModelBaker] 图为空，无法烘焙")
		return null

	var style: ToonStyleDef = opt.get("style", null)
	var palette: ToonPaletteDef = opt.get("palette", null)

	var vs := float(opt.get("voxel_size", 0.0))
	if vs <= 0.0:
		vs = style.voxel_size if style != null else 0.12

	var old_pivot := g.pivot
	var pv := int(opt.get("pivot", -1))
	if pv >= 0:
		g.pivot = pv

	g.set_seed(p_seed)
	var field := g.evaluate(vs, float(opt.get("margin", -1.0)))

	if bool(opt.get("style_geometry", true)):
		apply_style_geometry(field, style)

	# —— 产物 1/2：低多边形网格 ——
	var colors := slot_colors(palette)
	var mesh := MeshExtractor.extract(field,
		int(opt.get("algo", MeshExtractor.Algo.DUAL_CONTOURING)), {
			"vertex_colors": colors,
			"emit_slot_uv": bool(opt.get("emit_slot_uv", true)),
		})

	# —— 产物 2/2：体素网格（与上面共用这一次场）——
	var vox: SdfVoxel = null
	var vres := int(opt.get("voxel_res", 0))
	if vres > 0:
		vox = VoxelExtractor.extract(field, vres, {"palette": _as_color_array(colors)})
		if vox != null and bool(opt.get("voxel_slots", true)):
			apply_slots_to_voxel(field, vox, colors)

	g.pivot = old_pivot
	if mesh == null or mesh.is_empty():
		## 空网格没有摆放价值。常见原因是体素比几何最薄处还粗，
		## 或图的包围盒没盖住实际写出的形状（某个节点 bounds_hint 报小了）。
		push_warning("[ModelBaker] 烘焙出空网格（seed=%d, voxel=%.3f）；"
			% [p_seed, vs] + "检查节点 bounds_hint 是否覆盖实际形状，或调细体素。")
		return null

	var b := PropBuild.new()
	b.mesh = mesh
	b.voxel = vox
	b.bounds = mesh.local_aabb
	b.footprint = opt.get("footprint", _footprint_of(mesh))
	var meta: Dictionary = opt.get("meta", {})
	meta[&"seed"] = p_seed
	b.meta = meta
	return b

# ================================================================== 场级几何

## 按风格调整场的几何质感。
##
## 顺序是**先硬边化、后抽壳**，不能反：抽壳是 `abs(d) - w`，
## 若先抽壳再硬边化，量化作用在壳体上，壁厚会随位置起伏；
## 先硬边化再抽壳，内外两个面源自同一份已量化的场，壁厚才是均匀的。
static func apply_style_geometry(field: SdfField, style: ToonStyleDef) -> void:
	if field == null or style == null or field.is_empty():
		return
	if style.roughen > 0.0:
		SdfTool.harden(field, style.roughen)
	if style.shell > 0.0:
		SdfTool.shell(field, style.shell)
	if style.roughen > 0.0 or style.shell > 0.0:
		SdfTool.refresh_band_bounds(field)   ## 改写了 data，窄带缓存失效

# ================================================================== 槽位与配色

## 槽位 → 颜色的查找表。未给色板时全白（几何仍然正确，只是没有分件色）。
##
## 索引 0 刻意留作"未指定槽位"的兜底色，而 [constant SdfField.SLOT_NONE]（255）
## 是空哨兵、不会出现在表里 —— 于是"没指定槽位的体素"与"空体素"在数据上不会混淆。
static func slot_colors(palette: ToonPaletteDef) -> PackedColorArray:
	var out := PackedColorArray()
	out.resize(SdfField.SLOT_NONE)
	out.fill(Color.WHITE)
	if palette == null:
		return out
	var ramp := palette.to_array(SdfField.SLOT_NONE)
	for i in mini(ramp.size(), out.size()):
		out[i] = ramp[i]
	return out

## 把场的材质槽位写进体素调色板：每个体素按自己所在体素的槽位取色。
##
## 代价：这是对体素网格的**一趟额外全扫描**，GDScript 下大致
## 10 万体素 ~0.2 s、100 万体素 ~2 s。相对烘焙本身（秒级）可忽略，
## 但仍提供 `"voxel_slots": false` 让调用方按需关掉。
static func apply_slots_to_voxel(field: SdfField, vox: SdfVoxel, colors: PackedColorArray) -> void:
	if field == null or vox == null or not field.has_slots():
		return
	## 槽位 → 体素调色板下标。建表时把每个槽位的颜色吸附到 colors 里最近的一档，
	## 于是内层循环只是一次数组查表，不必逐体素做颜色比较。
	var tbl := PackedByteArray()
	tbl.resize(256)
	tbl.fill(0)
	for s in SdfField.SLOT_NONE:
		tbl[s] = _nearest_color(colors, colors[s] if s < colors.size() else Color.WHITE)

	var vs_field := field.voxel_size
	var org := field.origin
	var nx := vox.size.x
	var ny := vox.size.y
	var nz := vox.size.z
	var vs := vox.voxel
	for z in nz:
		for y in ny:
			var row := (z * ny + y) * nx
			var base_y := vox.origin.y + y * vs - org.y
			var base_z := vox.origin.z + z * vs - org.z
			for x in nx:
				var cur := vox.data[row + x]
				if cur == SdfVoxel.EMPTY:
					continue
				var lp_x := vox.origin.x + x * vs - org.x
				var lp_z := base_z
				var lp_y := base_y
				var vi := Vector3i(floori(lp_x / vs_field), floori(lp_y / vs_field),
					floori(lp_z / vs_field))
				vox.data[row + x] = tbl[field.slot_at_world(vi)]

static func _nearest_color(colors: PackedColorArray, c: Color) -> int:
	var best := 0
	var bd := INF
	for i in colors.size():
		var dr := colors[i].r - c.r
		var dg := colors[i].g - c.g
		var db := colors[i].b - c.b
		var d := dr * dr + dg * dg + db * db
		if d < bd:
			bd = d
			best = i
	return best

static func _as_color_array(src: PackedColorArray) -> Array:
	var out: Array = []
	out.resize(src.size())
	for i in src.size():
		out[i] = src[i]
	return out

static func _footprint_of(mesh: SdfMesh) -> Vector2:
	if mesh == null or mesh.is_empty():
		return Vector2.ZERO
	var b := mesh.local_aabb
	return Vector2(b.size.x, b.size.z)

# ================================================================== 可视化

## 装配成可视节点：三渲二材质 + 倒壳描边。
## 父节点负责摆到世界里 —— 本工具不碰位置，位置归 [PropLayoutTool]。
static func build_node(b: PropBuild, opt := {}) -> Node3D:
	var root := Node3D.new()
	root.name = String(opt.get("name", "Model"))
	if b == null or b.is_empty():
		return root
	var style: ToonStyleDef = opt.get("style", null)
	var palette: ToonPaletteDef = opt.get("palette", null)
	var mi := b.to_mesh_instance(null)
	mi.name = "Surface"
	root.add_child(mi)
	if style != null and palette != null:
		## apply 内部会换材质，并按 style.outline_mode 决定是否生成描边子节点
		ToonMaterial.apply(mi, style, palette, root)
	return root

## 把体素产物装配成可视节点。
##
## `&"greedy"`（默认 true）走贪心合并 —— 面色干净、面数低，适合三渲二与微缩感；
## false 走逐体素方块，是"看得见的方块"效果，更接近 Minecraft / MagicaVoxel 产物。
static func build_voxel_node(v: SdfVoxel, opt := {}) -> Node3D:
	var root := Node3D.new()
	root.name = String(opt.get("name", "Voxel"))
	if v == null or v.is_empty():
		return root
	var style: ToonStyleDef = opt.get("style", null)
	var palette: ToonPaletteDef = opt.get("palette", null)
	var colors := slot_colors(palette)
	var provider := _make_provider(colors, style, palette)
	var greedy := bool(opt.get("greedy", true))
	var mesh := v.to_greedy_mesh(provider) if greedy else v.to_item_mesh(provider)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = "Voxels"
	root.add_child(mi)
	if style != null and palette != null and bool(opt.get("outline", false)):
		ToonMaterial.apply(mi, style, palette, root)
	return root

## 体素调色板 → 材质。贪心合并出的每个调色板槽位一个材质。
static func _make_provider(colors: PackedColorArray, style: ToonStyleDef,
		palette: ToonPaletteDef) -> Callable:
	if style == null or palette == null:
		return Callable()
	## 只为"确实被用到"的槽位建材质：254 个材质里绝大多数没被用到，
	## 全建会让每帧的 material 切换与显存占用都无谓地翻十几倍。
	var used := {}
	for s in colors.size():
		used[_nearest_color(colors, colors[s])] = true
	var mats := {}
	for k in used.keys():
		mats[k] = style.make_material(palette)
	return func(slot: int) -> Material:
		return mats.get(slot, null)
