@tool
class_name ToonMaterial
## 三渲二材质与描边装配 —— 把「风格 + 配色」变成节点树里能直接看的东西
##
## 职责边界：本文件是**唯一**允许创建 MeshInstance3D / 写 material 的地方。
## 风格参数来自 `ToonStyleDef`，颜色来自 `ToonPaletteDef`，GLSL 来自 `ToonShader`，
## 本文件只做装配，不含任何美术判断（除了"要不要画描边"这一条路由）。
##
## == 两种倒壳描边，不要叠加 ==
##   · `build_outline_mesh()` —— **几何外扩**：把顶点沿法线推开，壳体是真实几何。
##     宽度是**世界空间恒定**（近处粗、远处细），适合导出 / 无 shader 管线 / 需要实体壳。
##   · `outline()` —— **着色器外扩**：宽度是**屏幕空间恒定**，适合实时观看。
## 两者效果重叠：已经外扩过网格就别再给着色器留宽度，否则描边粗一倍。
## `apply()` 默认走着色器外扩（实时观感优先），并在文档里给出接几何外扩的做法。

#region 材质

## 主色阶材质。`palette` 为 null 时返回只带 shader 的裸材质（可安全用于预览）。
##
## `use_vertex_color` = 让网格顶点色（`SlotPalette` 烘的语义分件色）参与取色，
## 详见 [method ToonStyleDef.make_material]。默认关闭。
static func surface(style: ToonStyleDef, palette: ToonPaletteDef, use_vertex_color := false,
		vcol_strength := 1.0, slot_ramp: Texture2D = null) -> ShaderMaterial:
	if style == null:
		return null
	return style.make_material(palette, use_vertex_color, vcol_strength, slot_ramp)


## 单一分件色材质：把 [member ToonPaletteDef.base] 换成 [param base_color] 造一份色阶材质。
##
## ============================ 为什么需要它 ============================
## [method surface] 只认"一份配色方案一个主色"，所以多分件场景里所有部件会拿到
## 同一个主色 —— 体素调色板把网格切成了几十个 surface，逐 surface 挂同一个材质，
## 于是**分色数据全在、渲染上看不出差别**（且不报任何错）。
##
## 三档怎么派生（与 [method ToonStyleDef.make_material] 的档位算法对齐）：
## 暗档向 [member ToonPaletteDef.shade] 与 [member ToonPaletteDef.deep] 靠，
## **亮档不在这里派生** —— 它由 [method ToonStyleDef.make_material] 拿
## [member ToonPaletteDef.base]（此处即 [param base_color]）唯一地派生一次。
## 也就是**换色相、不换画风**：档数 / 暗部染色 / 轮廓光 / 雾全部沿用 [param style]，
## 所以一堆零件仍然是同一种画风。
static func part_material(style: ToonStyleDef, palette: ToonPaletteDef,
		base_color: Color) -> ShaderMaterial:
	if style == null:
		return null
	if palette == null:
		return style.make_material(null)
	var sub := ToonPaletteDef.new()
	sub.base = base_color
	## —— 亮档必须留成base_color 原值，不能在这里预混 ——
	## [method ToonStyleDef.make_material] 拿到 palette 后**一定会**再执行一次
	## `palette.base.lerp(palette.light, 0.55)`。这里若先混一遍，同一个亮档端点
	## 就被 55% 混了两次（等效约 0.80），亮档必然贴到近白 —— 奶白/米色这类
	## 本身高明的部件色（面包店、墙面）会直接烧成纯白，整张画面褪成一片白。
	## 所以这里**只**预混暗档，亮档原样交给 [method ToonStyleDef.make_material]
	## 按base_color 唯一地派生一次。
	sub.shade = base_color.lerp(palette.shade, 0.62)
	sub.deep = base_color.lerp(palette.deep, 0.72)
	sub.accent = palette.accent
	sub.accent2 = palette.accent2
	sub.outline = palette.outline
	return style.make_material(sub)


## 逐调色板索引取色的材质提供者（体素分件的正规出口）。
##
## 返回 `func(palette_index: int, face_dir: int) -> Material`，正好是
## [method SdfVoxel.to_greedy_mesh] / [method PropBuild.to_mesh_instance] 认的签名。
##
## 索引 → 颜色走 [method ToonPaletteDef.to_array]（固定 swatch 色板会原样取出，
## 没有则退化成色阶），颜色 → 材质走 [method part_material]，材质**只造一次并缓存**：
## 体素网格的 surface 数可能上百，逐 surface 重建材质会让显存与切换成本翻几十倍。
static func voxel_material_provider(style: ToonStyleDef,
		palette: ToonPaletteDef) -> Callable:
	if style == null:
		return Callable()
	var pal := palette if palette != null else ToonPaletteDef.new()
	var colors := pal.to_array(255)
	if colors.is_empty():
		return Callable()
	var cache := {}
	return func(palette_index: int, _face_dir: int) -> Material:
		if cache.has(palette_index):
			return cache[palette_index]
		var m := part_material(style, pal,
			colors[clampi(palette_index, 0, colors.size() - 1)])
		cache[palette_index] = m
		return m


## 倒壳描边材质。`extra_width` 会**加**到 `style.outline_width` 上：
## 网格已经用 `build_outline_mesh()` 沿法线推开过，就传 `-style.outline_width` 抵消。
static func outline(style: ToonStyleDef, palette: ToonPaletteDef,
		extra_width := 0.0) -> ShaderMaterial:
	if style == null:
		return null
	var mat := ShaderMaterial.new()
	mat.shader = ToonShader.outline_shader()
	# 风格层是描边色的最终决定者；留空（全透明）时回退配色方案的描边色
	var col := style.outline_color
	if col.a <= 0.0:
		col = palette.outline if palette else Color(0.20, 0.15, 0.24, 1.0)
	mat.set_shader_parameter(&"u_outline_color", col)
	mat.set_shader_parameter(&"u_width", _hull_width(style, extra_width))
	return mat


## 倒壳外扩量的上限系数（相对 `style.voxel_size`）。
##
## 为什么要夹：壳是沿顶点法线**平移**出来的，遇到锐角（屋顶脊、柱头、窗棂这类）
## 平移量一旦接近甚至超过局部形体尺度，相邻壳面就会互相穿过 —— 表现为描边在
## 尖角处破口、闪烁。夹在 0.75 倍体素边长以内，实测观感仍是"细描边"，
## 但不会自交。网格闭合后（面完整了）这类尖角才处处存在，所以必须夹。
const HULL_WIDTH_VOXEL_RATIO := 0.75


## 实际使用的外扩宽度：先叠加 `extra_width`，再夹到不自交的区间。
static func _hull_width(style: ToonStyleDef, extra_width := 0.0) -> float:
	var cap := maxf(style.voxel_size * HULL_WIDTH_VOXEL_RATIO, 0.0)
	return clampf(style.outline_width + extra_width, 0.0, cap)

#endregion


#region 倒壳网格

## 几何外扩版倒壳网格：从源网格复制顶点，沿顶点法线按 `style.outline_width` 外扩，
## **翻转三角形绕序**（否则正反面判定反了，壳会挡住本体），法线保持为外扩方向。
##
## 只处理 surface 0（SDF 烘焙出的网格都是单 surface）。源网格为空 / 无顶点时安全返回 null。
## 顶点无法线数据时退化为原样复制（不猜法线——猜错会让壳体翻面）。
## 外扩量走 `_hull_width()`：夹在不自交的区间内，锐角处不会破口。
static func build_outline_mesh(mesh: ArrayMesh, style: ToonStyleDef) -> ArrayMesh:
	if mesh == null or style == null:
		return null
	var src := mesh.surface_get_arrays(0)
	if src.is_empty():
		return null
	var verts: PackedVector3Array = src[Mesh.ARRAY_VERTEX]
	if verts.is_empty():
		return null
	var norms: PackedVector3Array = src[Mesh.ARRAY_NORMAL]

	var out_verts := PackedVector3Array()
	out_verts.resize(verts.size())
	if norms.size() == verts.size():
		var w := _hull_width(style)
		for i in verts.size():
			out_verts[i] = verts[i] + norms[i] * w
	else:
		out_verts = verts

	var idx: PackedInt32Array = src[Mesh.ARRAY_INDEX]
	var out_idx := PackedInt32Array()
	if idx.size() >= 3:
		out_idx.resize(idx.size())
		for t in range(0, idx.size(), 3):
			out_idx[t] = idx[t]
			out_idx[t + 1] = idx[t + 2]
			out_idx[t + 2] = idx[t + 1]
	else:
		# 无索引面：补一份顺序索引，才能统一翻转绕序
		out_idx.resize(verts.size())
		for i in verts.size():
			out_idx[i] = i

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = out_verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = out_idx
	var out_mesh := ArrayMesh.new()
	out_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out_mesh

#endregion


#region 槽位色带

## 槽位查表用的 256×1 色带纹理宽度。
##
## 为什么是 256 而不是 255：shader 侧按 `floor(UV2.x * 256)` 反算槽位号，
## 索引空间必须与槽位空间**逐格对齐**（0~254 有效、255 恒空），
## 多出来的第 255 格填 [method make_slot_ramp] 的 `empty`，正好对应哨兵槽位。
const SLOT_RAMP_WIDTH := 256


## 把"槽位号 → 颜色"的表烘成 256×1 色带纹理，供 shader 按 UV2.x 查色。
##
## 入参直接吃 [method SlotPalette.to_array] 的返回值（`Array[Color]`，**按槽位号索引**），
## 因此不必让本文件认识 `SlotPalette` —— 避免 Style 层反向依赖 Tool 层。
##
## 换配色只需重烘这张纹理并重新 `set_shader_parameter(&"u_slot_ramp", ...)`，
## **网格完全不用重提**，这是顶点色通道做不到的。
##
## `empty` 填 255 号（哨兵）格；正常提取不会产出该槽（已折叠到 0 号），故填什么都安全，
## 默认全透明——真被读到时表现为"这块没颜色"，比错色更容易排查。
static func make_slot_ramp(colors: Array[Color],
		empty := Color(0.0, 0.0, 0.0, 0.0)) -> ImageTexture:
	var img := Image.create(SLOT_RAMP_WIDTH, 1, false, Image.FORMAT_RGBA8)
	var n := mini(colors.size(), SLOT_RAMP_WIDTH)
	for i in n:
		img.set_pixel(i, 0, colors[i])
	for i in range(n, SLOT_RAMP_WIDTH):
		img.set_pixel(i, 0, empty)
	# 不生成 mipmap：色带只有 1 像素高，且 mipmap 会引入跨槽位插值
	return ImageTexture.create_from_image(img)

#endregion


#region 一站式装配

## 倒壳子节点的固定名。重复调用 `apply()` 时按这个名字清理旧壳，避免叠出多圈描边。
const OUTLINE_NODE := &"Outline"

## 屏幕空间描边的标记 meta：防止把别的系统（悬停高亮）挂上的 overlay 当成自己的清掉。
const OUTLINE_META := &"toon_screen_outline"


## 一站式装配：换上色阶材质 + 按 `style.outline_mode` 决定描边怎么画。
##
## 返回**承载描边的节点**：倒壳模式返回新建的壳节点，其余模式返回 `mi` 本身
## （便于调用方统一记一笔，例如挂到自己的容器下）。
##
## `outline_parent` 为空时壳节点挂在 `mi` 下面；给一个父节点则挂到那里——
## 后者用于"壳节点需要独立变换 / 与本体错开"的场合。
##
## 可重复调用：同名旧壳会被清掉，屏幕空间标记也会先解再挂。
##
## `use_vertex_color` / `slot_ramp` 透传给 [method surface]：网格顶点色或槽位色带是
## 语义分件色时置 true / 传入色带。两条同时给时的错配告警由
## [method ToonStyleDef.make_material] 统一发出（本函数不重复报，否则一次调用会响两次）。
##
## `keep_material` 为 true 时**不碰** [member MeshInstance3D.material]，只负责描边。
## 典型场景是体素分件：表面材质已按调色板索引逐面指定（[method VoxelExtractor] 的
## `tint_regions` 产物），再统一赋值会把所有分件色压成同一个颜色。此时描边与
## 表面材质是两件正交的事，交给本函数只做描边那一半。
static func apply(mi: MeshInstance3D, style: ToonStyleDef, palette: ToonPaletteDef,
		outline_parent: Node = null, use_vertex_color := false,
		slot_ramp: Texture2D = null, keep_material := false) -> Node3D:
	if mi == null or style == null:
		return null
	if not keep_material:
		mi.material = surface(style, palette, use_vertex_color, 1.0, slot_ramp)
	_clear_outline(mi)
	match style.outline_mode:
		ToonStyleDef.OutlineMode.INVERTED_HULL:
			return _spawn_hull(mi, style, palette, outline_parent)
		ToonStyleDef.OutlineMode.SCREEN_SPACE:
			if _screen_space_outline(mi, true):
				return mi
			# 没挂 OutlineEffect 就退倒壳。两者观感都是"一圈硬边"，
			# 而"配置漏了一个后处理 ⇒ 整个描边消失"是严重得多的问题。
			push_warning("[ToonMaterial] 场景未挂 OutlineEffect，屏幕空间描边自动降级为倒壳。")
			return _spawn_hull(mi, style, palette, outline_parent)
		_:
			pass # OFF：材质已换好，不需要描边
	return mi

#endregion


#region 内部实现

## 倒壳：新建一个共用源网格、只换材质的 MeshInstance3D。
## 壳不投影也不被阴影接收——否则本体会被自己的壳挡出黑边。
static func _spawn_hull(mi: MeshInstance3D, style: ToonStyleDef, palette: ToonPaletteDef,
		outline_parent: Node) -> Node3D:
	if mi.mesh == null:
		return mi
	var hull := MeshInstance3D.new()
	hull.name = OUTLINE_NODE
	hull.mesh = mi.mesh
	hull.material_override = outline(style, palette)
	hull.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 壳只是壳：不参与遮挡剔除，transform 跟随本体（挂 mi 下时恒为单位变换）
	hull.extra_cull_margin = 0.0
	(outline_parent if outline_parent else mi).add_child(hull)
	hull.transform = mi.transform if outline_parent else Transform3D.IDENTITY
	return hull


## 屏幕空间描边：复用框架的 `OutlineEffect` 后处理（不自己实现膨胀算法）。
##
## 返回是否真的挂上了。槽位 0 没有实例（Compositor 没配）时返回 false，
## 由调用方决定降级路线 —— 这里**不崩、也不留半成品**，
## 更不会静默当作"已描边"（那会让整套画风悄悄丢掉最关键的一层轮廓）。
static func _screen_space_outline(mi: MeshInstance3D, on: bool) -> bool:
	if OutlineEffect._instances.is_empty():
		return false
	OutlineEffect.set_outlined(on, mi)
	mi.set_meta(OUTLINE_META, on)
	return true


## 清掉本模块此前挂上的描边（两种模式都清）。
static func _clear_outline(mi: MeshInstance3D) -> void:
	for c in mi.get_children():
		if c.name == OUTLINE_NODE:
			mi.remove_child(c)
			c.queue_free()
	if mi.has_meta(OUTLINE_META):
		_screen_space_outline(mi, false)

#endregion