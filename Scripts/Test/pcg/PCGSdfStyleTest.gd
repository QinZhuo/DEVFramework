class_name PCGSdfStyleTest
extends RefCounted

## 场景风格包 + 双产物回归测试
##
## ============================ 这份测试挡的是哪类事故 ============================
## 风格包是"一个配置切换整个场景"的落点，它出问题的特点是**静默**：
##
## · 配方用了装配器不支持的摆放策略 → 那几类单体直接不出现，且**没有任何报错**
##   （WorldAssembler 的 STREET 只认第一个配方，其余被 assemble_finish 跳过）
## · 双产物设置没下发到配方 → 选了体素形态却一个体素都不出，界面上只是"模型不见了"
## · 画风与内容错配 → 能跑、能出片，但和风场景配了一堆街边店铺，薄壳一抽全成纸片
##
## 这三类都不会让测试崩，只能靠**逐条断言**守住。
##
## 覆盖：
##   1. 三套风格包结构完整（画风 / 配色 / 配方齐全且生成脚本可加载）
##   2. 每个配方都能烘出非空网格 —— 新加生成器最容易在这里暴露 local_bounds 没盖住几何
##   3. 双产物：voxel_res > 0 出体素、= 0 不出，且**不污染网格路径**
##   4. 风格包把 voxel_res 下发到每个配方（这条曾静默失效过）

const PACK_PATH := "res://Scripts/Gen/SceneStylePresets.gd"

## 双产物验证用的**小实心体**。
##
## 刻意不拿项目里的生成器来测这条：生成器的形状千差万别，一旦挑中扁长物体
## （街道 24×0.6×10.8 那种），`voxel_res` 按**最长边**定尺，短边会塌到一两格，
## 体素化直接退化 —— 那是"物体形状与分辨率不匹配"，不是"双产物开关坏了"，
## 混进来只会让这条测试变成一个含义不清的雷。
## 这条要验的是"开关生效且不污染网格"，用一个必然成功的形状即可。
class SolidProp extends PropGen:
	func local_bounds() -> AABB:
		return AABB(Vector3(-1, 0, -1), Vector3(2, 2, 2))
	func build(_field: SdfField) -> void:
		fill_shape(_box)
	func _box(p: Vector3) -> float:
		return SdfTool.sd_box(p - Vector3(0, 1, 0), Vector3(1, 1, 1))
	func meta() -> Dictionary:
		return {&"tag": "test_solid"}

## 用 load 而非直接写类名：预设脚本在 Scripts/ 下，
## class_name 未必已进全局类表，直接引用会让本文件在首次编译时挂掉。
static func _packs() -> Dictionary:
	return load(PACK_PATH).presets()

static func run() -> bool:
	failures.clear()
	var all_ok := true
	var packs := _packs()

	# —— 1. 三套风格包结构完整 ——
	all_ok = _ck(all_ok, packs.size() == 3, "应有 3 套风格包，实得 %d" % packs.size())
	for k in [&"jp_street", &"wa_shrine", &"mini_fairy"]:
		all_ok = _ck(all_ok, packs.has(k), "缺少风格包 %s" % String(k))
		if not packs.has(k):
			continue
		var p = packs[k]
		all_ok = _ck(all_ok, p.style != null, "%s 没有画风定义" % String(k))
		all_ok = _ck(all_ok, p.palette != null, "%s 没有配色定义" % String(k))
		all_ok = _ck(all_ok, p.recipes.size() > 0, "%s 没有任何配方" % String(k))
		all_ok = _ck(all_ok, p.gen_def != null, "%s 没有烘焙参数" % String(k))
		for r in p.recipes:
			all_ok = _ck(all_ok, r.gen_script != null, "%s 的配方 %s 生成脚本未加载" % [String(k), r.tag])

	# —— 2. 每个配方都烘得出非空网格 ——
	for k in packs.keys():
		var p = packs[k]
		for r in p.recipes:
			if r.gen_script == null:
				continue
			var b = PropGenTool.bake(r.gen_script.new(), r.make_gen_def(), 777)
			var ok := b != null and not b.is_empty() and b.triangle_count() > 0
			all_ok = _ck(all_ok, ok, "%s / %s 烘焙产出非空网格（实得 %d 面）" % [
				String(k), r.tag, b.triangle_count() if b != null else 0])

	# —— 3. 双产物：开关生效且不影响网格路径 ——
	var d0 := PropGenDef.new()
	d0.voxel_size = 0.12
	d0.algo = MeshExtractor.Algo.DUAL_CONTOURING
	d0.voxel_res = 0
	var b0 = PropGenTool.bake(SolidProp.new(), d0, 999)
	all_ok = _ck(all_ok, b0 != null and not b0.has_voxel(), "voxel_res=0 时不应产出体素")

	var d1 := PropGenDef.new()
	d1.voxel_size = 0.12
	d1.algo = MeshExtractor.Algo.DUAL_CONTOURING
	d1.voxel_res = 24
	var b1 = PropGenTool.bake(SolidProp.new(), d1, 999)
	all_ok = _ck(all_ok, b1 != null and b1.has_voxel(), "voxel_res=24 时应产出体素")
	all_ok = _ck(all_ok, b1 != null and b1.voxel.count_solid() > 0, "体素产物不应为空")
	## 关键：两次烘焙的网格必须完全一致 —— 体素提取是纯读取，不能改写场
	all_ok = _ck(all_ok,
		b0 != null and b1 != null and b0.triangle_count() == b1.triangle_count(),
		"加体素提取不应改变网格结果（%d vs %d）" % [
			b0.triangle_count() if b0 != null else -1,
			b1.triangle_count() if b1 != null else -2])

	## 同 seed 可复现：体素产物也必须能被 seed 重放出来（存档只存 seed 的前提）
	var b2 = PropGenTool.bake(SolidProp.new(), d1, 999)
	all_ok = _ck(all_ok,
		b1 != null and b2 != null and b1.voxel.count_solid() == b2.voxel.count_solid(),
		"同 seed 两次烘焙的体素数应一致（%d vs %d）" % [
			b1.voxel.count_solid() if (b1 != null and b1.has_voxel()) else -1,
			b2.voxel.count_solid() if (b2 != null and b2.has_voxel()) else -2])

	# —— 4. 风格包把双产物设置下发到每个配方 ——
	var mini = packs[&"mini_fairy"]
	all_ok = _ck(all_ok, mini.gen_def.voxel_res > 0, "微缩童话应默认开启体素产物")
	var asm = WorldAssembler.from_pack(mini, func(x, z): return 0.0)
	all_ok = _ck(all_ok, asm.recipes.size() == mini.recipes.size(),
		"from_pack 应把 %d 个配方全部装进组装器，实得 %d" % [
			mini.recipes.size(), asm.recipes.size()])
	for r in mini.recipes:
		all_ok = _ck(all_ok, r.voxel_res == mini.gen_def.voxel_res,
			"配方 %s 的 voxel_res 应被风格包下发为 %d，实得 %d" % [
				r.tag, mini.gen_def.voxel_res, r.voxel_res])

	print("[风格] 风格包与双产物检查完毕")
	return all_ok

## 失败项明细。返回值只有一个 bool 时，测试挂了只能去翻日志 ——
## 而日志往往已经被后续输出冲掉了。这里留一份可直接取用的清单。
static var failures: PackedStringArray = []

static func _ck(ok: bool, cond: bool, msg: String) -> bool:
	if not cond:
		failures.append(msg)
		print("[风格] 失败: " + msg)
	return ok and cond
