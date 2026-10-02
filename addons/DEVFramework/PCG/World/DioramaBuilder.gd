@tool
class_name DioramaBuilder extends RefCounted
## 微缩小场景构建器 —— **底座 + 簇式布局**
##
## ============================ 与 WorldAssembler 的区别 ============================
## [WorldAssembler] 是**街道式线性布局**：沿 +X 首尾相铺一条主街，其余挂在街道锚点上。
## 本类是**簇式布局**：主体落圆心、环境沿背板弧线围合、道具环绕成圈，
## 全部限制在一块展示底座内。两者不可互换 ——
## 拿街道布局摆 diorama，所有道具会被摊成一条直线；
## 拿簇式布局摆街道，主体和环境会挤成一团。
##
## 两者共享同一份契约：生成器只写局部几何（[PropGen] → [PropBuild]），
## 落位一律交给布局层（[PropLayoutTool]），本类**不含任何几何语义**。
##
## ============================ 分帧 ============================
## 烘焙是本模块唯一耗时环节（见 [method WorldAssembler.assemble_step] 的说明）。
## 一套 diorama 十几个单体，一次性跑完会白屏十几秒，
## 且场景尚未切换完毕时连 [method Node.get_tree] 都可能拿不到 current_scene，
## 自动化工具会据此误判为崩溃。所以默认走 [method begin] / [method step] / [method finish]。
## [method build] 是同步快捷方式，仅供测试与小体量使用。
##
## == 用法 ==
## [codeblock]
## var db := DioramaBuilder.new()
## db.begin(def, recipes, 42)
## while not db.step():
##     bar.value = db.progress() * 100.0
##     await get_tree().process_frame
## var b := db.finish()
## print(b.story(), "｜完整度问题：", b.validate())
## [/codeblock]

## 布局抖动的固定 slot。用固定值而非"配方数量"：这样往配方表里**追加**一条
## 不会改变既有道具的落位（同 [method PCGTool.derive_seed] 的 slot 约定）。
const LAYOUT_SLOT := 9001

## 底座在 build 缓存里的键（底座不走 [method _key] 的 "tag:seed" 形式）
const BASE_KEY := "__base__"

var _def: DioramaDef = null
var _recipes: Array = []
var _seed := -1
var _queue: Array = []
var _builds := {}
var _cache := {}
var _total := 0
var _done := 0


# ============================================================== 同步快捷方式

## 一次性建完。**会阻塞主线程**，体量的 diorama 请改用 [method begin]/[method step]。
static func build(def: DioramaDef, recipes: Array, world_seed: int) -> DioramaBuild:
	var b := DioramaBuilder.new()
	b.begin(def, recipes, world_seed)
	while not b.step():
		pass
	return b.finish()


# ============================================================== 第 1 阶段：分帧烘焙

## 准备一次构建。会清空上一次的任务队列与本次的 build 结果，
## 但**不清**烘焙缓存（[member _cache]）—— 切回旧 seed 时因此是毫秒级返回。
func begin(def: DioramaDef, recipes: Array, world_seed: int) -> void:
	_def = def
	_recipes = recipes if recipes != null else []
	_seed = world_seed
	_queue.clear()
	_builds.clear()
	_done = 0
	_total = 0
	if _def == null:
		return
	if _def.base_gen != null:
		_total += 1
	for r in _recipes:
		if _valid(r):
			_total += r.count
	if _def.base_gen != null:
		_queue.append({"base": true})
	for r in _recipes:
		if not _valid(r):
			continue
		for i in r.count:
			_queue.append({"r": r, "i": i})


## 烘一个单体，返回 true 表示烘焙阶段已全部结束。
func step() -> bool:
	if _queue.is_empty():
		return true
	var job: Dictionary = _queue.pop_front()
	if bool(job.get("base", false)):
		var bb := _bake_base()
		if bb != null:
			_builds[BASE_KEY] = bb
	else:
		var r: DioramaRecipe = job["r"]
		var i: int = job["i"]
		var sd := PropGenTool.mix_seed(_seed, r.kind_id, i)
		var b := _bake(r, _resolve_gen_def(r), sd)
		if b != null:
			_builds[_key(r, i)] = b
	_done += 1
	return _queue.is_empty()


## 烘焙进度 [0.0, 1.0]，仅供 UI 显示。
func progress() -> float:
	if _total <= 0:
		return 1.0
	return clampf(float(_done) / float(_total), 0.0, 1.0)


## 尚未烘焙的个体数。
func pending() -> int:
	return _queue.size()


# ============================================================== 第 2 阶段：簇式落位

## 烘完之后落位。耗时毫秒级，可与最后一次 [method step] 同帧调用。
func finish() -> DioramaBuild:
	var out := DioramaBuild.new()
	out.world_seed = _seed
	if _def == null:
		return out
	out.base = _builds.get(BASE_KEY, null)
	out.base_radius = _base_radius(out.base)

	## 布局抖动用**独立随机流**（固定 slot 派生），与烘焙随机互不干扰 ——
	## 否则加一个道具会改变所有道具的落位。
	var lrng := PCGTool.make_rng(PCGTool.derive_seed(_seed, LAYOUT_SLOT))

	var all := []
	for r in _recipes:
		if not _valid(r):
			continue
		for pl in _layout_recipe(r, lrng, out.base_radius):
			out.add(pl, r.role)
			all.append(pl)

	## 全局避让：同类挤环带、跨类抢位（车压到人行道上）一并推开
	PropLayoutTool.relax(all, _def.relax_iterations, _def.shrink)
	## 吸附必须在 relax **之后**：relax 会把摆放推开，事先吸附等于白做。
	## 先解冲突、再量化到格点，两个目标才都成立。
	if _def.voxel_grid_snap > 0.0:
		for p in all:
			var pl: PropLayoutTool.Placement = p
			if pl != null:
				snap_to_grid(pl, _def.voxel_grid_snap)
	out.bounds = _world_bounds(out)
	return out


## 把一个摆放吸附到体素格点（XZ 平面）。
##
## [param step] 为 0 时什么都不做 —— 网格风格场景必须保持随机摆放，
## 否则整场会退化成机械的格子阵。
static func snap_to_grid(pl: PropLayoutTool.Placement, step: float) -> void:
	if pl == null or step <= 0.0:
		return
	var o := pl.xform.origin
	o.x = snappedf(o.x, step)
	o.z = snappedf(o.z, step)
	pl.xform.origin = o


func _layout_recipe(r: DioramaRecipe, lrng: RandomNumberGenerator, base_r: float) -> Array:
	var res := []
	var n := r.count
	for i in n:
		var b: PropBuild = _builds.get(_key(r, i))
		if b == null:
			continue
		var ang := _angle_for(r, i, n, lrng)
		var rad := _radius_for(r, lrng)
		var at := Vector2(cos(ang), sin(ang)) * rad

		## 越界剔除：外缘超出底座就整个不摆（留 [member DioramaDef.overhang] 余量）。
		## 必须在 solve 之前判 —— 摆到边界上被硬切，看着像被一堵墙挡住。
		##
		## 逐轴判，不按外接圆判：方底座的外接圆比边长多 √2 倍，
		## 沿对角线量会放过四条边中段的一批悬空道具。
		## 物体的外缘用未旋转的 footprint 近似（偏保守：转 45° 的长椅按轴对齐算，
		## 结果只会剔得更多，不会放过）—— yaw 在这之后才算出来。
		if _def.constrain_to_base and base_r > 0.0:
			var half := _def.base_half_extent()
			var lim := half * (1.0 + _def.overhang)
			var half_fp := b.footprint * 0.5
			if absf(at.x) + half_fp.x > lim.x or absf(at.y) + half_fp.y > lim.y:
				continue

		var opts := {
			&"y_offset": r.y_offset,
			&"ground_step": _def.ground_step,
		}
		if r.snap >= 0:
			opts[&"snap"] = r.snap

		var yaw := 0.0
		var radial := Vector2(cos(ang), sin(ang))
		match r.facing:
			DioramaRecipe.Facing.CENTER:
				opts[&"align_dir"] = -radial
			DioramaRecipe.Facing.OUTWARD:
				opts[&"align_dir"] = radial
			DioramaRecipe.Facing.TANGENT:
				opts[&"align_dir"] = Vector2(-radial.y, radial.x)
			DioramaRecipe.Facing.FIXED:
				yaw = deg_to_rad(maxf(r.angle, 0.0))
		if r.facing != DioramaRecipe.Facing.FIXED:
			## face_dir 由生成器自报（"我的正面朝哪面"），框架不猜
			opts[&"face_dir"] = b.meta.get(&"face_dir", Vector3i(0, 0, 1))

		var sd := PropGenTool.mix_seed(_seed, r.kind_id, i)
		var p := PropLayoutTool.solve(b, sd, at, yaw, _ground(), opts)
		if p == null:
			continue
		p.meta[&"tag"] = r.tag
		p.meta[&"role"] = r.role
		p.meta[&"band"] = r.band
		## 记下"本应产出体素"，供 [method DioramaBuild.validate] 抓体素化退化。
		## 两个字段都要看：只填 [member DioramaRecipe.voxel_cell] 时 voxel_res 仍是 0
		## （真正的分辨率由 [method _resolve_gen_def] 现场反算），只看 voxel_res 会漏判。
		p.meta[&"want_voxel"] = r.voxel_res > 0 or r.voxel_cell > 0.0
		res.append(p)
	return res


## 方位角（弧度）。
##
## 三种落位各自的角分布：
## · CENTER   → 取配方给的角（默认 0），抖动按 1/4 计（主体不该乱转）
## · BACKDROP → 在 [member DioramaDef.backdrop_arc] 那段弧上均分（含两端）
## · RING     → angle ≥ 0 时以它为**相位起点**，再按 count 均分整周；
##                angle < 0 时直接按 count 均分整周
func _angle_for(r: DioramaRecipe, i: int, n: int, lrng: RandomNumberGenerator) -> float:
	var jit := deg_to_rad(lrng.randf_range(-r.angle_jitter, r.angle_jitter))
	match r.layout:
		DioramaRecipe.Layout.CENTER:
			return deg_to_rad(maxf(r.angle, 0.0)) + jit * 0.25
		DioramaRecipe.Layout.BACKDROP:
			var t := 0.0
			if n > 1:
				t = (float(i) / float(n - 1)) - 0.5
			return deg_to_rad(_def.backdrop_angle) + t * deg_to_rad(_def.backdrop_arc) + jit
		_:
			## angle 是相位而非"全部实例的同一个角"：后者会让 count=2 的两盏路灯
			## 叠在同一个坐标上，relax 再怎么推也只会在原地打转。
			var phase := deg_to_rad(maxf(r.angle, 0.0))
			return phase + (float(i) / float(maxf(float(n), 1.0))) * TAU + jit


## 半径（米）。[member DioramaRecipe.radius] ≥ 0 时直接用，否则按环带推导。
##
## [b]CENTER 必须归零[/b]：否则主体会被推到 [member DioramaDef.inner_radius] 那一圈上 ——
## 那个半径是"道具从哪一圈往外排"，主体本该落在它**内圈的空地**上。
## 少了这个分支，主体和道具会排在同一圈上互相推挤，最后谁也没站在中间。
func _radius_for(r: DioramaRecipe, lrng: RandomNumberGenerator) -> float:
	var rad := r.radius
	if rad < 0.0:
		rad = 0.0 if r.layout == DioramaRecipe.Layout.CENTER \
			else _def.radius_for_band(r.band)
	return rad + lrng.randf_range(-r.radius_jitter, r.radius_jitter)


## 展示底座基本是平的，地面查询退化为常量高度。
##
## 仍然传一个**有效**的 Callable（而不是留空）：留空会让 [method PropLayoutTool.solve]
## 的贴地退化成 [constant PropLayoutTool.Snap.NONE]，于是不做 `lift` 补偿 ——
## 生成器 local_bounds 的 y 从负值起时，单体会整个陷进底座。
func _ground() -> Callable:
	var top := _def.base_top
	return func(_x: float, _z: float) -> float:
		return top


# ============================================================== 烘焙与缓存

## 配方有效性。[param _recipes] 是未类型化数组（框架不类型注解，见 [member SceneStylePack.recipes]
## 的同款理由），所以先判类型再取属性 —— 否则塞进来一个 Dictionary 会直接崩在属性访问上。
func _valid(r: Variant) -> bool:
	return r is DioramaRecipe and r.gen_script != null and r.count > 0


## 烘焙参数 + 按目标体素边长反算分辨率。
##
## [member DioramaRecipe.voxel_res] 是"最长边切几格"，而体素方块的**物理边长**
## = 物体尺寸 / voxel_res。同一场景里物体大小差几十倍，各填各的分辨率必然得到
## 大小悬殊的方块，"统一正方体"就不成立。填 [member DioramaRecipe.voxel_cell]
## （米）则由各物体自己的尺寸反推，全场方块边长一致。
##
## [b]换算基准是 local_bounds 的最长边，不含 margin[/b]：
## [method VoxelExtractor.extract] 先取 [method SdfTool.band_bounds]（贴着表面的紧包围盒）
## 再交给 [method VoxelExtractor._grid] 算 `voxel = 最长边 / res`，
## 所以 margin 只是把场分配得更大，不进这项换算。拿 margin 补偿会让实际方块
## 系统性偏小 margin/res（本例 0.4/64 ≈ 6 毫米）。
func _resolve_gen_def(r: DioramaRecipe) -> PropGenDef:
	var gd := r.make_gen_def()
	## 这里**不能**再要求 `gd.voxel_res > 0`：voxel_res 默认 0，而本函数的存在意义
	## 就是"只填 voxel_cell，由各物体尺寸反推 voxel_res"。早先那句附加条件会让
	## [member DioramaRecipe.voxel_res] 留空的配方（也就是绝大多数按文档写的配方）
	## 直接原样返回、voxel_res 仍是 0，于是体素产物为空 ——
	## 而画面上不报错、只是少了整套体素表现，最难归因。
	if r.voxel_cell <= 0.0:
		return gd
	## 探一次生成器只为拿尺寸。刻意不调 prepare()：它会消耗 rng，
	## 而真正烘焙时 [method PropGenTool.bake] 会用全新的 rng 重新 prepare，
	## 这里消耗的是另一个实例的 rng，不影响可复现性。
	var probe: PropGen = r.gen_script.new()
	probe.gen_def = gd
	var bb := probe.local_bounds()
	var longest := maxf(bb.size.x, maxf(bb.size.y, bb.size.z))
	if longest > 0.0:
		gd.voxel_res = clampi(int(round(longest / r.voxel_cell)), 4, 256)
	return gd


func _bake(r: DioramaRecipe, gd: PropGenDef, sd: int) -> PropBuild:
	var k := "%s:%d" % [r.tag, sd]
	if _cache.has(k):
		return _cache[k]
	var gen: PropGen = r.gen_script.new()
	var b := PropGenTool.bake(gen, gd, sd)
	if b == null or b.is_empty():
		## 空网格没有摆放价值。症状是"某类道具 quietly 消失"，所以必须留警告 ——
		## 本模块最常见的坑就是体素精度比几何最薄处还粗。
		push_warning("[DioramaBuilder] %s 烘焙出空网格（seed=%d, voxel=%.3f, voxel_res=%d）"
			% [r.tag, sd, gd.voxel_size, gd.voxel_res])
		return null
	_cache[k] = b
	return b


func _bake_base() -> PropBuild:
	if _def == null or _def.base_gen == null:
		return null
	var ck := "base:%d" % _seed
	if _cache.has(ck):
		return _cache[ck]
	var gd: PropGenDef = _def.base_def if _def.base_def != null else PropGenDef.new()
	var gen: PropGen = _def.base_gen.new()
	var b := PropGenTool.bake(gen, gd, PropGenTool.mix_seed(_seed, 977, 0))
	if b == null or b.is_empty():
		push_warning("[DioramaBuilder] 底座烘焙出空网格，检查 base_gen 的 local_bounds 是否盖住 build()")
		return null
	_cache[ck] = b
	return b


static func _key(r: DioramaRecipe, i: int) -> String:
	return "%s#%d" % [r.tag, i]


static func _base_radius(base: PropBuild) -> float:
	if base == null:
		return 0.0
	var s := base.bounds.size
	return maxf(s.x, s.z) * 0.5


## 整个 diorama 的世界包围盒（底座 + 全部摆放）。
static func _world_bounds(b: DioramaBuild) -> AABB:
	var acc := AABB()
	var first := true
	if b.base != null and not b.base.is_empty():
		acc = b.base.bounds
		first = false
	for p in b.all():
		var pl: PropLayoutTool.Placement = p
		if pl == null or pl.build == null:
			continue
		var wb: AABB = pl.xform * pl.build.bounds
		if first:
			acc = wb
			first = false
		else:
			acc = acc.merge(wb)
	return acc


# ============================================================== 输出

## 摆进场景树：底座落在原点，其余按各自 transform。父节点只当容器。
##
## [param material] 为 null 时不覆盖材质 —— 调用方通常想用
## [method SceneStylePack.apply_material] 逐个上画风（那样才有描边）。
##
## [param form] 投影形态，**整场统一**下发，见 [enum PropBuild.Form]。
## 体素场景传 [constant PropBuild.Form.VOXEL_ITEM] 可拿到"每个方块独立可辨"的
## Minecraft / MagicaVoxel 观感，也是验证体素一致性的基准形态。
static func spawn(b: DioramaBuild, parent: Node, material: Variant = null,
		form: PropBuild.Form = PropBuild.Form.AUTO) -> Node3D:
	var root := Node3D.new()
	root.name = "Diorama"
	if parent != null:
		parent.add_child(root)
	if b == null:
		return root
	if b.base != null and not b.base.is_empty():
		var mi := PropGenTool.instantiate(b.base, material, form)
		if mi != null:
			mi.name = "Base"
			root.add_child(mi)
	for p in b.all():
		var pl: PropLayoutTool.Placement = p
		if pl == null or pl.build == null:
			continue
		var mi2 := pl.instantiate(material, form)
		if mi2 == null:
			continue
		mi2.name = "%s_%d" % [pl.meta.get(&"tag", "prop"), pl.seed_value]
		root.add_child(mi2)
	return root


## 存档：只记 seed + 位置 + 朝向，**不记网格**（铁律②）。
## 读档时用同一套 [DioramaDef] 与 world_seed 重跑 [method begin]/[method finish] 即可还原。
static func save_data(b: DioramaBuild) -> Array:
	var rows := []
	if b == null:
		return rows
	for p in b.all():
		var pl: PropLayoutTool.Placement = p
		if pl == null:
			continue
		rows.append({
			&"tag": pl.meta.get(&"tag", ""),
			&"role": pl.meta.get(&"role", 0),
			&"seed": pl.seed_value,
			&"x": pl.xform.origin.x,
			&"y": pl.xform.origin.y,
			&"z": pl.xform.origin.z,
			&"yaw": pl.yaw,
		})
	return rows
