@tool
class_name WorldAssembler
extends RefCounted
## 世界组装器 —— 项目的「最终布局层」
##
## ============================ 它是什么 ============================
## 把各个**独立生成器**产出的单体摆到合适的位置、朝向、贴地、互不重叠，
## 然后交出 [codeblock][PropLayoutTool.Placement][/codeblock] 列表。
##
## ============================ 它不是什么 ============================
## ❌ 不含任何"世界数据包" —— 这里没有一个对象装着所有世界内容。
##    形状永远留在 ShopGen / HospitalGen / VehicleGen / StreetGen 各自的
##    build() 里；组装器拿到的只是一句"我占地 6×4.8，正面朝 +Z，贴地"。
## ❌ 不做造型决策 —— 改不了顶点、加不了细节。
## ❌ 不认识具体物体 —— 它不知道"医院"比"店"重要，只知道后者 footprint 更大。
##
## 换一款游戏，这里几乎一字不改可用；换一款游戏要改的是**配方**和生成器。
##
## ============================ 两阶段 ============================
## [br]1. 烘焙[/br] 先把每个配方要的单体按 seed 烘出来（带缓存）。
##    [br]2. 布局[/br] 再决定它们站哪、朝哪。
## 顺序不能反：偏移量要用到 build.footprint，没烘出来就算不出"离路缘多远"。

## 单体配方表。世界长什么样，全看这张表。
var recipes: Array[PropRecipe] = []

## 追加配方。外部用 [method add_recipe] 逐个填，
## 而不是直接给 [member recipes] 赋一个无类型 Array（会被类型化数组拒绝）。
func add_recipe(r: PropRecipe) -> WorldAssembler:
	if r != null:
		recipes.append(r)
	return self

func clear_recipes() -> void:
	recipes.clear()
	_cache.clear()

## 按风格包建一个装配器。[param ground_y] 为地面查询，见 [member ground_y]。
##
## 为什么这一步在**项目层**而不是 [SceneStylePack] 上：
## 风格包是框架类，它不认识本项目的 [WorldAssembler]；反向由项目来建，
## 依赖方向才是单向的（项目 → 框架）。
static func from_pack(pack: SceneStylePack, ground_y := Callable()) -> WorldAssembler:
	var a := WorldAssembler.new()
	if pack == null:
		return a
	a.ground_y = ground_y
	a.street_step = pack.street_step
	## ★ 双产物设置必须逐个配方下发，否则"这套场景要出体素"会静默失效
	## （组装器烘焙时用的是配方自己的烘焙参数，不是包的 gen_def）。
	pack.apply_output_to_recipes()
	for r in pack.recipes:
		a.add_recipe(r as PropRecipe)
	return a

## 地面查询（鸭子类型）：func(x: float, z: float) -> float。
## 留空则全部单体落在 y=0（做俯视平面布局或配纯平地形时够用）。
var ground_y := Callable()

## 主街采样步长（米）。路面有 24m 长，采样太稀会直接穿过地形。
var street_step := 4.0

## 避让收缩系数：1.0 = 严格不重叠，0.9 = 允许挤压（街道更紧凑）
var shrink := 0.95

## build 缓存：key = "tag:seed"。同 seed 全世界只烘一次。
var _cache := {}

## —— 分帧烘焙状态 ——
var _step_seed := -1
var _step_queue: Array = []
var _step_builds := {}
var _step_total := 0
var _step_done := 0


## —— 入口 ——

## 组装整个世界。返回所有摆放（不创建节点）。
##
## 一次性跑完，中途不 relinquish 主线程 —— 中等精度下会堵住十几秒。
## 需要保持界面响应时改用 [method assemble_step] + [method assemble_finish]。
func assemble(world_seed: int) -> Array:
	while not assemble_step(world_seed):
		pass
	return assemble_finish(world_seed)


## 分帧烘焙：**每次只烘一个单体**，返回 true 表示烘焙阶段已全部结束。
##
## 为什么需要它：烘焙是本模块唯一的耗时环节（中等精度下单体 1~3 秒），
## 而布局只要几毫秒。一次性 [method assemble] 会把主线程堵住十几秒，
## 表现是窗口白屏、UI 不响应；更糟的是场景切换尚未完成，
## 连 [method Node.get_tree] 都可能拿不到 [member SceneTree.current_scene]，
## 自动化工具会据此误判为崩溃。
##
## 典型用法：
## [codeblock]
## while not asm.assemble_step(world_seed):
##     show_progress(asm.step_progress())
##     await get_tree().process_frame
## var placements := asm.assemble_finish(world_seed)
## [/codeblock]
##
## 命中缓存的单体几乎瞬时返回，所以切回旧 seed 时整体依然很快。
func assemble_step(world_seed: int) -> bool:
	if _step_seed != world_seed:
		_step_seed = world_seed
		_step_queue.clear()
		for r in recipes:
			if r == null or r.gen_script == null or r.count <= 0:
				continue
			for i in r.count:
				_step_queue.append([r, i])
		_step_builds.clear()
		_step_total = _step_queue.size()
		_step_done = 0
	if not _step_queue.is_empty():
		var job: Array = _step_queue.pop_front()
		var r: PropRecipe = job[0]
		var i: int = job[1]
		## 单体 seed 由 (world_seed, kind_id, index) 派生：
		## 换地图 seed 会改变布局，但每个 index 的形状仍由自己的 seed 唯一决定。
		var sd := PropGenTool.mix_seed(world_seed, r.kind_id, i)
		var b := _bake(r, r.make_gen_def(), sd)
		if b != null:
			_step_builds[_key(r, i)] = b
		_step_done += 1
		return false    ## 每帧只做一个单体
	return true


## 烘焙结束后摆放。耗时毫秒级，可与最后一次 [method assemble_step] 同帧调用。
func assemble_finish(_world_seed := 0) -> Array:
	if _step_builds.is_empty():
		return []

	## 主街先摆：它是锚，其余单体要贴着它排
	var street := _layout_street(_step_builds)
	var out := street.duplicate()

	for r in recipes:
		if r == null or r.count <= 0:
			continue
		match r.place:
			PropRecipe.Place.STREET:
				pass    ## 已由 _layout_street 处理
			PropRecipe.Place.STREET_SIDE:
				out.append_array(_layout_street_side(r, _step_builds, street))
			PropRecipe.Place.ROADSIDE:
				out.append_array(_layout_roadside(r, _step_builds, street))
			PropRecipe.Place.LANDMARK:
				out.append_array(_layout_landmark(r, _step_builds))

	## 全局避让：同侧建筑沿街排队，跨类别（车压到人行道上）一并推开
	PropLayoutTool.relax(out, 32, shrink)
	return out


## 分帧烘焙进度 [0.0, 1.0]。仅供 UI 显示，不影响逻辑。
func step_progress() -> float:
	if _step_total <= 0:
		return 1.0
	return clampf(float(_step_done) / float(_step_total), 0.0, 1.0)


## 尚未烘焙的单体数。
func step_pending() -> int:
	return _step_queue.size()


## 摆进场景树。父节点只当容器，不参与任何摆放计算。
func spawn(placements: Array, parent: Node, material: Material = null) -> Node3D:
	var root := Node3D.new()
	root.name = "World"
	parent.add_child(root)
	for p in placements:
		var pl: PropLayoutTool.Placement = p
		var mi := pl.instantiate(material)
		if mi == null:
			continue
		mi.name = "%s_%d" % [pl.meta.get(&"tag", "prop"), pl.seed_value]
		root.add_child(mi)
	return root


## 存档：只记 seed + 位置 + 朝向，**不记网格**。
## 读档时用同一套配方与 world_seed 重跑 [method assemble] 即可完整还原。
static func save_data(placements: Array) -> Array:
	var rows := []
	for p in placements:
		var pl: PropLayoutTool.Placement = p
		rows.append({
			&"tag": pl.meta.get(&"tag", ""),
			&"seed": pl.seed_value,
			&"x": pl.xform.origin.x,
			&"y": pl.xform.origin.y,
			&"z": pl.xform.origin.z,
			&"yaw": pl.yaw,
		})
	return rows

## —— 第 1 阶段：烘焙 ——
## 由 [method assemble_step] 逐个完成（可分帧），此处只提供单个单体的烘焙与缓存。

func _bake(r: PropRecipe, gd: PropGenDef, sd: int) -> PropBuild:
	var k := "%s:%d" % [r.tag, sd]
	if _cache.has(k):
		return _cache[k]
	var gen: PropGen = r.gen_script.new()
	var b := PropGenTool.bake(gen, gd, sd)
	if b == null or b.is_empty():
		## 空网格没有摆放价值，当作没烘出来直接丢弃：
		## 常见原因是几何比体素还薄（采样点整体落在实体外），或
		## local_bounds 没盖住 build() 写出的部分。宁可少摆一个，也别摆一个错位的。
		push_warning("[WorldAssembler] %s 烘焙出空网格，检查 local_bounds 是否覆盖了 build() 写出的几何，"
			+ "或体素精度是否比几何最薄处还粗（seed=%d, voxel=%.3f）" % [r.tag, sd, gd.voxel_size])
		return null
	_cache[k] = b
	return b


## —— 第 2 阶段：布局 ——

## 主街：沿 +X 首尾平铺成一条直线。街道不按 4 角贴地（会翘），
## 按 [constant PropLayoutTool.Snap.CENTER] + 密集采样跟随地形起伏。
func _layout_street(builds: Dictionary) -> Array:
	var out := []
	var r := _recipe_at(PropRecipe.Place.STREET)
	if r == null:
		return out
	var x := 0.0
	for i in r.count:
		var b: PropBuild = builds.get(_key(r, i))
		if b == null:
			continue
		var p := PropLayoutTool.solve(
			b, PropGenTool.mix_seed(0, r.kind_id, i), Vector2(x, 0.0), 0.0, ground_y,
			{&"snap": PropLayoutTool.Snap.CENTER, &"ground_step": street_step})
		if p == null:
			continue
		p.meta[&"is_street"] = true
		out.append(p)
		## 下一段接在这段末端：路面必须首尾相接，中间留缝会看到缺口
		x += b.footprint.x
	return out


## 沿街两侧：每段街道两侧各放一个，正面朝街道。
## 离路缘的距离由**建筑自己的 footprint** 决定 —— 组装器不需要知道店有几米深，
## 它只知道"这个单体半深 2.4，往外挪 2.4 就贴上路缘了"。
func _layout_street_side(r: PropRecipe, builds: Dictionary, street: Array) -> Array:
	var out := []
	for i in r.count:
		var b: PropBuild = builds.get(_key(r, i))
		if b == null:
			continue
		## 交替左右，并让建筑数量与街道段数对齐（多出来的沿街继续排）
		var anchor: PropLayoutTool.Placement = street[i % street.size()] if street.size() > 0 else null
		var side := 1.0 if i % 2 == 0 else -1.0
		var at := Vector2(0.0, side * 40.0)
		var off := Vector2.ZERO
		if anchor != null:
			at = Vector2(anchor.xform.origin.x, anchor.xform.origin.z)
			## 街道半宽 → 建筑半深，中间留出路肩
			off = Vector2(0.0, side * (anchor.build.footprint.y * 0.5 + b.footprint.y * 0.5 + 1.0))
			at += off
		var p := PropLayoutTool.solve(
			b, PropGenTool.mix_seed(0, r.kind_id, i), at, 0.0, ground_y, _face_opts(r, at, side))
		if p:
			out.append(p)
	return out


## 路肩停车：车头顺着街道方向（+X），停在路缘外侧。
func _layout_roadside(r: PropRecipe, builds: Dictionary, street: Array) -> Array:
	var out := []
	for i in r.count:
		var b: PropBuild = builds.get(_key(r, i))
		if b == null:
			continue
		var anchor: PropLayoutTool.Placement = street[i % street.size()] if street.size() > 0 else null
		var at := Vector2(float(i) * 6.0, 5.2)
		if anchor != null:
			at = Vector2(anchor.xform.origin.x, anchor.xform.origin.z + 5.2)
		var p := PropLayoutTool.solve(
			b, PropGenTool.mix_seed(0, r.kind_id, i), at, 0.0, ground_y, {
				&"align_dir": Vector2(1, 0),
				&"face_dir": b.meta.get(&"face_dir", Vector3i(1, 0, 0)),
			})
		if p:
			out.append(p)
	return out


## 独立地块：远离街道的一侧，避免与街面建筑抢位。
func _layout_landmark(r: PropRecipe, builds: Dictionary) -> Array:
	var out := []
	for i in r.count:
		var b: PropBuild = builds.get(_key(r, i))
		if b == null:
			continue
		## 沿 -Z 排开，每个体量之间留出自己的宽度
		var z := -60.0
		for j in i:
			var prev: PropBuild = builds.get(_key(r, j))
			if prev != null:
				z -= prev.footprint.y * 0.5
		var at := Vector2(0.0, z)
		for j in i:
			var prev: PropBuild = builds.get(_key(r, j))
			if prev != null:
				z -= prev.footprint.y * 0.5 + 4.0
		var p := PropLayoutTool.solve(
			b, PropGenTool.mix_seed(0, r.kind_id, i), at, 0.0, ground_y, _face_opts(r, at, 1.0))
		if p:
			out.append(p)
	return out


## —— 内部工具 ——

## 建筑朝向：街两侧的面朝街道（side 决定往 +Z 还是 -Z 转）
func _face_opts(r: PropRecipe, at: Vector2, side: float) -> Dictionary:
	if not r.align_to_street:
		return {&"y_offset": r.y_offset}
	return {
		&"align_dir": Vector2(0, -side),
		&"face_dir": Vector3i(0, 0, 1),
		&"y_offset": r.y_offset,
		&"ground_step": street_step,
	}

func _recipe_at(place: PropRecipe.Place) -> PropRecipe:
	for r in recipes:
		if r != null and r.place == place:
			return r
	return null

func _key(r: PropRecipe, i: int) -> String:
	return "%s#%d" % [r.tag, i]
