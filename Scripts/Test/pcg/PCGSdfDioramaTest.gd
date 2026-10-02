class_name PCGSdfDioramaTest
extends RefCounted

## 微缩小场景（diorama）回归 —— 「展示底座 + 簇式布局」这条链路的结构性质
##
## 本测试不关心几何长什么样（那是 [PCGSdfGenTest]），也不关心街道式排布
## （那是 [PCGSdfWorldTest]）。它只抓 diorama **特有**的那几条：
##   · 三种落位（CENTER / BACKDROP / RING）各自的语义真的成立
##   · 越界剔除按逐轴半尺寸判，不会放过悬空道具
##   · 体素场景里**全场方块边长一致**（voxel_cell 的下发链）
##   · 分帧烘焙（begin/step/finish）与同步 build 结果一致
##   · 同 seed 必复现、换 seed 必变、存档只存 seed + transform
##
## == 夹具为什么这么"瘦" ==
## 结构性质与精度无关，而一次 [method PropGenTool.bake] 的耗时**主要不在体素**：
## 实测同一生成器把 voxel_cell 从 0.3 放到 0.6，体素数掉到 1/10 而耗时几乎不变。
## 所以提速靠的是**少用大生成器**（面包店 / 邻栋各 2.7~5.4 秒）而不是调精度。
## 生产精度（[constant DioramaPresets.CELL] 0.12 米）的整体表现由演示场景
## `Scenes/PCG/PCGDioramaDemo.tscn` 负责，不进单测。

## 测试用的目标体素边长（米）。
##
## 0.3 是**能出体素的下限附近**：路灯灯杆只有十几厘米粗，0.4 时整个细杆会跨不满一格
## ⇒ 体素产物为空、场景静默退回网格（[method DioramaBuild.validate] 会报"体素化退化"）。
## 这不是夹具随便挑的数字，而是"细长物体需要多细的格子"这条事实的最小复现。
const CELL_TEST := 0.3

const GEN_DIR := "res://Scripts/Gen/Diorama/"


# ============================================================== 夹具

## 一份最小可用的 [DioramaDef]：有底座、有环带、有背板弧，开体素吸附。
static func _def(cell: float) -> DioramaDef:
	var d := DioramaDef.new()
	d.base_gen = load(GEN_DIR + "VoxelSquareBaseGen.gd")
	var bd := PropGenDef.new()
	bd.voxel_size = 0.3
	bd.margin = 0.3
	bd.algo = MeshExtractor.Algo.DUAL_CONTOURING
	bd.voxel_cell = cell
	bd.voxel_palette = VoxelSkin.palette()
	d.base_def = bd
	d.base_top = 0.0
	d.inner_radius = 2.6
	d.ring_step = 0.7
	d.backdrop_angle = 90.0
	d.backdrop_arc = 90.0
	d.shrink = 0.9
	d.relax_iterations = 28
	d.voxel_grid_snap = cell
	d.accent_lights = [
		{&"color": Color(1, 0.9, 0.6), &"energy": 1.2, &"radius": 2.0,
			&"offset": Vector3(0, 0, -1.1), &"height": 1.8, &"flicker": 0.0},
	]
	return d


static func _recipe(tag: String, gen_file: String, count: int, role: int,
		opt: Dictionary, cell: float) -> DioramaRecipe:
	var r := DioramaRecipe.new()
	r.tag = tag
	r.gen_script = load(GEN_DIR + gen_file)
	r.count = count
	r.role = role
	r.voxel_size = 0.3
	r.voxel_cell = cell
	r.voxel_palette = VoxelSkin.palette()
	for k in opt.keys():
		r.set(StringName(k), opt[k])
	return r


## 四条配方覆盖三种落位与三种角色。生成器一律选小的（邮筒 / 路灯）——
## 这里要验的是**布局层**，拿最重的生成器来验布局是浪费。
static func _recipes(cell: float) -> Array:
	return [
		## 主体：CENTER 落位，半径显式给 1.1（朝镜头侧，与生产预设同思路）
		_recipe("mailbox_main", "MailboxGen.gd", 1, DioramaRecipe.Role.SUBJECT, {
			"layout": DioramaRecipe.Layout.CENTER,
			"radius": 1.1, "angle": 270.0, "radius_jitter": 0.0, "angle_jitter": 0.0,
			"facing": DioramaRecipe.Facing.OUTWARD, "kind_id": 1,
		}, cell),
		## 环境：BACKDROP 落位。**必须是 count=2 的一条配方**，不能拆成两条 count=1 ——
		## BACKDROP 的角位由 count 在弧上均分（含两端），count=1 时 t 恒为 -0.5，
		## 两条 count=1 会落在**同一个角**上，再被 relax 推开成随机的一对。
		_recipe("wall", "MailboxGen.gd", 2, DioramaRecipe.Role.ENV, {
			"layout": DioramaRecipe.Layout.BACKDROP,
			"radius": 3.4, "angle_jitter": 0.0, "radius_jitter": 0.0,
			"facing": DioramaRecipe.Facing.CENTER, "kind_id": 2,
		}, cell),
		## 道具：RING 落位，angle 是**相位** ⇒ 两盏路灯相差 180°，而不是叠在一起
		_recipe("lamp", "StreetLampGen.gd", 2, DioramaRecipe.Role.PROP, {
			"layout": DioramaRecipe.Layout.RING, "band": 1, "angle": 230.0,
			"angle_jitter": 0.0, "radius_jitter": 0.0,
			"radius": 3.6, "facing": DioramaRecipe.Facing.TANGENT, "kind_id": 4,
		}, cell),
	]


## 只含一盏路灯的**带抖动**配方。抖动必须开：布局抖动走独立随机流，
## 零抖动时换 world_seed 摆位一模一样，拿它验"换 seed 必须变"是假通过。
static func _jitter_recipes(cell: float) -> Array:
	return [
		_recipe("lamp_j", "StreetLampGen.gd", 1, DioramaRecipe.Role.PROP, {
			"layout": DioramaRecipe.Layout.RING, "band": 0, "angle": 230.0,
			"angle_jitter": 12.0, "radius_jitter": 0.4,
			"facing": DioramaRecipe.Facing.TANGENT, "kind_id": 4,
		}, cell),
	]


static func _deg(v: Vector3) -> float:
	return rad_to_deg(atan2(v.z, v.x))


## 按 tag 取出该套场景里的全部摆放。
static func _tagged(b: DioramaBuild, tag: String) -> Array:
	var out := []
	for p in b.all():
		var pl: PropLayoutTool.Placement = p
		if pl != null and String(pl.meta.get(&"tag", "")) == tag:
			out.append(pl)
	return out


## 两套构建的摆放是否逐个一致（数量 + 位置 + 朝向）。
static func _same(a: DioramaBuild, b: DioramaBuild) -> bool:
	if a.all().size() != b.all().size():
		return false
	for i in a.all().size():
		var pa: PropLayoutTool.Placement = a.all()[i]
		var pb: PropLayoutTool.Placement = b.all()[i]
		if not pa.xform.origin.is_equal_approx(pb.xform.origin) or absf(pa.yaw - pb.yaw) > 1e-6:
			return false
	return true


# ============================================================== 用例

static func run() -> bool:
	var all_ok := true
	var seed_value := 20261002

	# 主构建走**分帧**（演示场景的路线），对照构建走同步 build。
	# 一次比较同时覆盖两件事：两条路线结果一致 + 全新构建器独立重烘可复现。
	var t0 := Time.get_ticks_msec()
	var db := DioramaBuilder.new()
	db.begin(_def(CELL_TEST), _recipes(CELL_TEST), seed_value)
	var frames := 0
	while not db.step():
		frames += 1
	var b := db.finish()
	var sync := DioramaBuilder.build(_def(CELL_TEST), _recipes(CELL_TEST), seed_value)
	var ms := Time.get_ticks_msec() - t0

	var def := _def(CELL_TEST)

	# —— 1. Def 的取值只有一个真值来源：半径现算，且逐轴半尺寸不大于外接圆 ——
	var band_ok := absf(def.radius_for_band(0) - def.inner_radius) < 0.001 \
		and absf(def.radius_for_band(2) - (def.inner_radius + 2.0 * def.ring_step)) < 0.001
	var half := def.base_half_extent()
	var radius_ok := def.base_radius() > 0.0 and half.x > 0.0 and half.y > 0.0 \
		and half.length() <= def.base_radius() + 0.001
	all_ok = all_ok and band_ok and radius_ok
	print("[微缩] Def 取值: 环带 %s ｜ 底座半径 %.2f / 逐轴半尺寸 %.2f×%.2f: %s" % [
		band_ok, def.base_radius(), half.x, half.y, radius_ok])

	# —— 2. 完整度：底座 / 主体 / 环境 / 道具齐全，且体素没退化 ——
	# validate() 覆盖的正是"少一类道具时不报错、只是安静地少东西"这个坑。
	var bad := b.validate()
	var vcount := b.voxel_count()
	var ok2 := bad.is_empty() and vcount > 0
	all_ok = all_ok and ok2
	print("[微缩] 完整度自检: %s ｜ %s ｜ 体素块 %d" % [ok2, b.story(), vcount])
	if not bad.is_empty():
		print("[微缩]   完整度问题：", bad)

	# —— 3. 角色分组：主体 1 / 环境 2 / 道具 2，且 all() 是三者之和 ——
	var n_sub := b.subjects.size()
	var n_env := b.env.size()
	var n_prop := b.props.size()
	var group_ok := n_sub == 1 and n_env == 2 and n_prop == 2 \
		and b.all().size() == n_sub + n_env + n_prop \
		and b.by_role(DioramaRecipe.Role.ENV).size() == n_env
	all_ok = all_ok and group_ok
	print("[微缩] 角色分组: %s (主体 %d · 环境 %d · 道具 %d)" % [
		group_ok, n_sub, n_env, n_prop])

	# —— 4. CENTER 落位：主体落在配方给的半径上，且在镜头侧（-Z）——
	var main_sub := _tagged(b, "mailbox_main")
	var center_ok := main_sub.size() == 1
	if center_ok:
		var o: Vector3 = main_sub[0].xform.origin
		## relax 还会做避让推开，所以半径给 0.6 的松弛量
		center_ok = absf(Vector2(o.x, o.z).length() - 1.1) < 0.6 and o.z < 0.0
	all_ok = all_ok and center_ok
	print("[微缩] 主体居中落位: %s (%s)" % [center_ok,
		snappedf(Vector2(main_sub[0].xform.origin.x, main_sub[0].xform.origin.z).length(), 0.01)
			if main_sub.size() > 0 else "-"])

	# —— 5. BACKDROP 落位：两件围合件分居弧线两端（45° / 135°），弧心夹在中间 ——
	# 容差 20°：relax 会为避让把挤在一起的东西推开，弧端点是"起点"不是"终点"。
	var walls := _tagged(b, "wall")
	var back_ok := walls.size() == 2
	if back_ok:
		var a0 := _deg(walls[0].xform.origin)
		var a1 := _deg(walls[1].xform.origin)
		var lo := minf(a0, a1)
		var hi := maxf(a0, a1)
		## 弧心 90°、张角 90° ⇒ 合法区间 [45°, 135°]
		back_ok = lo >= 25.0 and hi <= 155.0 and absf((hi - lo) - 90.0) < 25.0
	all_ok = all_ok and back_ok
	print("[微缩] 背板弧落位(45°~135°，±20° 容差): %s (%s / %s)" % [back_ok,
		snappedf(_deg(walls[0].xform.origin), 0.1) if walls.size() == 2 else "-",
		snappedf(_deg(walls[1].xform.origin), 0.1) if walls.size() == 2 else "-"])

	# —— 6. RING 落位：angle 是**相位**，count=2 必须相差 180° 而不是叠在一起 ——
	# 这条是 RING 最容易踩的坑：把 angle 当"所有实例的同一个角"，
	# 两盏路灯会落在同一坐标，relax 再怎么推也只在原地打转。
	var lamps := _tagged(b, "lamp")
	var ring_ok := lamps.size() == 2
	if ring_ok:
		var d := absf(_deg(lamps[0].xform.origin) - _deg(lamps[1].xform.origin))
		ring_ok = absf(absf(d) - 180.0) < 25.0 \
			and Vector2(lamps[0].xform.origin.x, lamps[0].xform.origin.z).distance_to(
				Vector2(lamps[1].xform.origin.x, lamps[1].xform.origin.z)) > 3.0
	all_ok = all_ok and ring_ok
	print("[微缩] 环带相位均分整周: %s (角差 %.1f°)" % [ring_ok,
		absf(_deg(lamps[0].xform.origin) - _deg(lamps[1].xform.origin)) if lamps.size() == 2 else -1.0])

	# —— 7. 越界剔除按逐轴半尺寸判：外缘不得越过 底座半尺寸 ×(1+overhang) ——
	var lim := half * (1.0 + def.overhang)
	var edge_ok := true
	for p in b.all():
		var pl: PropLayoutTool.Placement = p
		if pl == null or pl.build == null:
			continue
		var o := pl.xform.origin
		var hf := pl.build.footprint * 0.5
		if absf(o.x) + hf.x > lim.x + 0.001 or absf(o.z) + hf.y > lim.y + 0.001:
			edge_ok = false
			print("[微缩]   越界未剔除: %s @ (%.2f, %.2f) 外缘 (%.2f, %.2f) > (%.2f, %.2f)"
				% [pl.meta.get(&"tag", "?"), o.x, o.z, absf(o.x) + hf.x,
					absf(o.z) + hf.y, lim.x, lim.y])
	all_ok = all_ok and edge_ok
	print("[微缩] 越界剔除(≤%.2f×%.2f): %s" % [lim.x, lim.y, edge_ok])

	# —— 8. 体素格点吸附：落位 XZ 必须落在 voxel_cell 的整数倍上 ——
	# 每个单体的体素格点锚在**它自己的局部原点**上，不吸附就会出现半格错位，
	# "统一正方体"就散了。吸附必须发生在 relax **之后**（见 DioramaBuilder.finish）。
	var snap_ok := true
	for p in b.all():
		var pl: PropLayoutTool.Placement = p
		if pl == null:
			continue
		var o := pl.xform.origin
		if absf(o.x / CELL_TEST - roundf(o.x / CELL_TEST)) > 1e-4 \
				or absf(o.z / CELL_TEST - roundf(o.z / CELL_TEST)) > 1e-4:
			snap_ok = false
			print("[微缩]   未吸附: %s @ (%.4f, %.4f)" % [pl.meta.get(&"tag", "?"), o.x, o.z])
	all_ok = all_ok and snap_ok
	print("[微缩] 体素格点吸附(%.2f m): %s" % [CELL_TEST, snap_ok])

	# —— 9. 全场体素边长一致：voxel_cell 经 make_gen_def 直达提取器 ——
	# 方块的物理边长是物理量，只能直接指定；换成"最长边切几格"必然漂。
	var cells := {}
	for p in b.all():
		var pl: PropLayoutTool.Placement = p
		if pl == null or pl.build == null or not pl.build.has_voxel():
			continue
		cells[snappedf(pl.build.voxel.voxel, 0.0001)] = true
	var cell_ok := cells.size() == 1 and float(cells.keys()[0]) > 0.0
	all_ok = all_ok and cell_ok
	print("[微缩] 全场体素边长一致: %s (%s，目标 %.2f)" % [cell_ok, cells.keys(), CELL_TEST])

	# —— 10. 分帧 == 同步 == 独立重烘：三条路线必须给出同一个 diorama ——
	var same := _same(b, sync)
	all_ok = all_ok and same
	print("[微缩] 分帧(%d 帧)/同步/独立重烘三者一致: %s" % [frames, same])

	# —— 11. 换 world_seed 必须换布局（用带抖动的单配方夹具，见 _jitter_recipes）——
	var j1 := DioramaBuilder.build(_def(CELL_TEST), _jitter_recipes(CELL_TEST), seed_value)
	var j2 := DioramaBuilder.build(_def(CELL_TEST), _jitter_recipes(CELL_TEST), seed_value + 1)
	var changed := not _same(j1, j2)
	all_ok = all_ok and changed
	print("[微缩] 换 world_seed 布局改变(带抖动夹具): %s" % changed)

	# —— 12. spawn：底座 + 全部摆放各一个 MeshInstance3D，且网格非空 ——
	var host := Node3D.new()
	var root := DioramaBuilder.spawn(b, host, null, PropBuild.Form.VOXEL_ITEM)
	var mis := root.get_children().filter(func(c): return c is MeshInstance3D)
	var want_n := b.all().size() + (1 if b.base != null else 0)
	var spawn_ok := mis.size() == want_n
	for c in mis:
		var mi := c as MeshInstance3D
		if mi.mesh == null or mi.mesh.get_surface_count() <= 0:
			spawn_ok = false
	host.free()
	all_ok = all_ok and spawn_ok
	print("[微缩] spawn 产出 %d/%d 个网格实例: %s" % [mis.size(), want_n, spawn_ok])

	# —— 13. 存档：只记 seed + 位置 + 朝向，绝不含网格 ——
	var rows := DioramaBuilder.save_data(b)
	var fields_ok := rows.size() == b.all().size()
	for r in rows:
		if not (r.has(&"tag") and r.has(&"seed") and r.has(&"x") and r.has(&"y") \
				and r.has(&"z") and r.has(&"yaw")) or r.size() != 7:
			fields_ok = false
	all_ok = all_ok and fields_ok
	print("[微缩] 存档仅含 %d 字段/条(无网格): %s" % [
		rows[0].size() if rows.size() > 0 else 0, fields_ok])

	print("[微缩] 全流程 %dms（体素 %d 块 / 三角面 %d）" % [
		ms, b.voxel_count(), b.triangle_count()])
	print("== SDF 微缩场景测试 %s ==" % ("全部通过" if all_ok else "存在失败"))
	return all_ok
