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
## · 镜头参数没给 / 给了一半 → 微缩感三要素（长焦 / 景深 / 暗角）缺一即失效，
##   画面退回"游戏截图"，同样**不报错**
##
## 这三类都不会让测试崩，只能靠**逐条断言**守住。
##
## 覆盖：
##   1. 三套风格包结构完整（画风 / 配色 / 配方齐全且生成脚本可加载）
##   2. 每个配方都能烘出非空网格 —— 新加生成器最容易在这里暴露 local_bounds 没盖住几何
##   3. 双产物：voxel_res > 0 出体素、= 0 不出，且**不污染网格路径**
##   4. 风格包把 voxel_res 下发到每个配方（这条曾静默失效过）
##   5. 体素与网格**同源**：格点容器罩住网格包围盒、中心重合、边长跟着几何尺度走、
##      实心体素数随几何体积变化（不是一份"看着对"的常量副本）
##   6. 镜头与舞台：字段语义自洽 + [MiniatureStage] 真的写进了场景 + 重复调用不叠层
##   7. 主光对齐：实灯出光方向必须与材质里的 `u_key_dir` 同向（Godot 没有 `LIGHT`
##      内置量，色阶方向只由这个 uniform 决定，两者错开即出现"硬边阴影与色阶打架"）

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

## 边长翻倍的同款立方体（4 米）。**只为验证"体素跟着几何走"**：
## 体素产物曾经有过"与场无关、像是上一份拷贝"的问题，
## 而那种 bug 在固定形状的用例上完全看不出来 —— 形状不变，数当然不变。
class BigProp extends PropGen:
	func local_bounds() -> AABB:
		return AABB(Vector3(-2, 0, -2), Vector3(4, 4, 4))
	func build(_field: SdfField) -> void:
		fill_shape(_box)
	func _box(p: Vector3) -> float:
		return SdfTool.sd_box(p - Vector3(0, 2, 0), Vector3(2, 2, 2))
	func meta() -> Dictionary:
		return {&"tag": "test_big"}

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

	# —— 3b. 同源：体素与网格必须出自**同一次场** ——
	#
	# 为什么这四条不是"重复验证已有功能"：双产物一旦不是同源的，
	# 所有已有断言（面数一致、可复现、非空）**照样全过** ——
	# 因为它们检查的是"体素产物自洽"，而错位发生在"体素 vs 网格"之间。
	# 表现是"两种输出对照"模式下两个模型整体错开，而烘焙日志一片正常。
	#
	# ① 格点容器必须罩住网格包围盒：两者都取自同一份窄带（SdfTool.band_bounds），
	#    只差一个网格化余量。若来自不同的场 / 不同的 origin，网格会整体落在容器之外。
	#    容差放宽到一个体素（窄带取景会略微外扩，且体素中心取样本身有半格偏移）。
	var vb: AABB = b1.voxel.bounds().grow(b1.voxel.voxel)
	all_ok = _ck(all_ok, vb.encloses(b1.mesh.local_aabb),
		"体素格点容器 %s 应罩住网格包围盒 %s（同一次场的两条投影必须同框）" % [
			vb, b1.mesh.local_aabb])
	# ② 中心必须重合：同一份窄带的对称中心，不同源时两者会各偏各的
	var dcen: float = b1.voxel.center().distance_to(b1.mesh.local_aabb.get_center())
	all_ok = _ck(all_ok, dcen <= b1.voxel.voxel,
		"体素与网格中心应重合，实差 %.3f 米（体素边长 %.3f）" % [dcen, b1.voxel.voxel])
	# ③ 体素边长按"最长边 / res"定尺 ⇒ 必须跟着几何尺度走，不能是写死的常数
	var ms: Vector3 = b1.mesh.local_aabb.size
	var mesh_longest: float = maxf(ms.x, maxf(ms.y, ms.z))
	var span: float = float(b1.voxel.res) * b1.voxel.voxel
	all_ok = _ck(all_ok, span >= mesh_longest and span <= mesh_longest * 1.8,
		"体素采样跨度 %.2f 应与网格最长边 %.2f 同量级（含窄带外扩）" % [span, mesh_longest])
	# ④ 实心体素数必须随几何体积变化：4 米块用 res=48 让体素边长与 2 米块基本一致，
	#    于是体积翻 8 倍 ⇒ 实心体素也应翻好几倍。写死或复用旧结果会让这条立刻掉到 1 倍。
	var d2 := PropGenDef.new()
	d2.voxel_size = 0.12
	d2.algo = MeshExtractor.Algo.DUAL_CONTOURING
	d2.voxel_res = 48
	var b3 = PropGenTool.bake(BigProp.new(), d2, 999)
	all_ok = _ck(all_ok, b3 != null and b3.has_voxel(), "4 米块也应产出体素")
	if b3 != null and b3.has_voxel():
		var ratio := float(b3.voxel.count_solid()) / maxf(float(b1.voxel.count_solid()), 1.0)
		all_ok = _ck(all_ok, ratio > 4.0 and ratio < 20.0,
			"体积翻 8 倍后实心体素应显著增多，实得 %.1f 倍（%d vs %d）" % [
				ratio, b3.voxel.count_solid(), b1.voxel.count_solid()])

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

	# —— 5. 镜头与舞台 ——
	all_ok = _stage_checks(all_ok, packs)

	print("[风格] 风格包与双产物检查完毕")
	return all_ok


## 微缩舞台检查：字段语义自洽 + [MiniatureStage] 真的写进场景 + 重复调用不叠层。
##
## 为什么要"实际写入"而不是只断言字段有值：微缩感三要素（长焦 / 浅景深 / 暗角）
## 任一为 0，画面就退回"游戏截图"，而这既不崩也不报错。
## 只查字段等于默认值，等于什么都没验 —— 所以这里在**临时场景树**上真跑一遍。
static func _stage_checks(all_ok: bool, packs: Dictionary) -> bool:
	for k in packs.keys():
		var p = packs[k]
		var tag := String(k)
		all_ok = _ck(all_ok, p.camera_fov < 70.0,
			"%s 的长焦 FOV 应明显低于人眼默认的 70°，实得 %.1f" % [tag, p.camera_fov])
		all_ok = _ck(all_ok, p.dof_amount > 0.0 and p.dof_far_distance > 0.0
				and p.dof_far_transition > 0.0,
			"%s 开了景深就必须同时给出虚化起点与过渡长度，否则整幅画一样清楚" % tag)
		## 过渡长度 ≥ 起点意味着"糊"的区间根本不存在（起点已经落在过渡里）
		all_ok = _ck(all_ok, p.dof_far_transition < p.dof_far_distance,
			"%s 的远景过渡(%.1f) 不应 ≥ 虚化起点(%.1f)" % [tag,
				p.dof_far_transition, p.dof_far_distance])
		all_ok = _ck(all_ok, p.env_fog_enabled and not p.env_fog_sky_affect,
			"%s 的雾应开启且**不染天空**（染了背景就灰，摆件感立刻消失）" % tag)
		all_ok = _ck(all_ok, p.disable_ssao and p.disable_glow,
			"%s 应显式关掉 SSAO 与 glow（会把硬色阶 / 硬描边糊成一团）" % tag)
		all_ok = _ck(all_ok, p.vignette_enabled and p.vignette_strength > 0.0
				and p.vignette_grain < 0.05,
			"%s 应开暗角，且胶片颗粒 < 0.05（再大就不是胶片、屏幕脏了）" % tag)
		## 主光来向必须是**单位向量且不与 UP 共线**：零向量会在 shader 里退化成 NaN，
		## 与 UP 共线则让 `look_at` 报"上方向与前方向共线" —— 两种都是静默坏掉。
		var aim: Vector3 = p.style.key_light_aim()
		all_ok = _ck(all_ok, is_equal_approx(aim.length(), 1.0)
				and absf(aim.dot(Vector3.UP)) < 0.999,
			"%s 的主光来向应是单位向量且不与 UP 共线，实得 %s" % [tag, aim])

	# —— 实际落地 + 幂等：在临时场景树上跑两遍 ——
	var mini = packs[&"mini_fairy"]
	var host := Node3D.new()
	var cam := Camera3D.new()
	host.add_child(cam)

	# 第一遍：场景里**故意不放** WorldEnvironment，验证 apply_stage 会自动补一个
	mini.apply_stage(host, cam, 62.0)
	all_ok = _ck(all_ok, absf(cam.fov - mini.camera_fov) < 0.01,
		"apply_camera 应把 FOV 写成 %.1f，实得 %.1f" % [mini.camera_fov, cam.fov])
	var attr = cam.attributes as CameraAttributesPractical
	all_ok = _ck(all_ok, attr != null,
		"apply_camera 应挂上 CameraAttributesPractical（景深只有它有）")
	if attr != null:
		all_ok = _ck(all_ok, attr.dof_blur_far_enabled and attr.dof_blur_near_enabled,
			"dof_amount > 0 时虚化开关必须打开，否则距离参数写了也不生效")
		all_ok = _ck(all_ok, is_equal_approx(attr.dof_blur_amount, mini.dof_amount),
			"虚化强度应等于风格包的 dof_amount（%.2f vs %.2f）" % [
				attr.dof_blur_amount, mini.dof_amount])
		all_ok = _ck(all_ok, is_equal_approx(attr.dof_blur_far_distance, mini.dof_far_distance),
			"远景虚化距离应等于风格包的 dof_far_distance")

	var wes: Array = host.find_children("*", "WorldEnvironment", true, false)
	all_ok = _ck(all_ok, wes.size() == 1,
		"场景原本没有 WorldEnvironment，apply_stage 应补出且**恰好一个**，实得 %d 个" % wes.size())
	var env: Environment = (wes[0] as WorldEnvironment).environment if wes.size() > 0 else null
	all_ok = _ck(all_ok, env != null, "补出的 WorldEnvironment 应带一个 Environment")
	if env != null:
		all_ok = _ck(all_ok, env.fog_enabled == mini.env_fog_enabled,
			"环境雾开关应跟随风格包")
		all_ok = _ck(all_ok, is_equal_approx(env.tonemap_exposure, mini.exposure),
			"曝光应落在 Environment.tonemap_exposure（%.2f vs %.2f）" % [
				env.tonemap_exposure, mini.exposure])
		## 微缩预设走 FLAT 背景 ⇒ 环境光必须从"纯色"取，否则纯色背景配高环境光
		## 会得到一幅看不出环境光的死平画面
		all_ok = _ck(all_ok, env.background_mode == Environment.BG_COLOR
				and env.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR,
			"FLAT 背景应配纯色环境光源（否则环境光取的是上一份天空或黑）")
		## 雾色 / 环境光的真值必须来自 ToonStyleDef 而不是风格包上另填一份：
		## 两处各填一次的颜色必然会互相打架
		all_ok = _ck(all_ok, env.ambient_light_color.is_equal_approx(mini.style.ambient)
				and env.fog_light_color.is_equal_approx(mini.style.fog_color),
			"环境光色/雾色应直接取自 style.ambient / style.fog_color，不另填一份")
		all_ok = _ck(all_ok, env.ssao_enabled == false and env.glow_enabled == false,
			"三渲二应显式关掉 SSAO 与 glow")

	var vl = _vignette_of(host)
	all_ok = _ck(all_ok, vl != null, "apply_stage 应挂上暗角层（微缩感第三要素）")
	if vl != null:
		all_ok = _ck(all_ok, vl.get_child_count() == 1,
			"暗角层里应恰好一个全屏 ColorRect，实得 %d 个" % vl.get_child_count())
		var rect := vl.get_child(0) as ColorRect
		var sm := rect.material as ShaderMaterial if rect != null else null
		all_ok = _ck(all_ok, sm != null and sm.shader == ToonShader.vignette_shader(),
			"暗角材质应是 ToonShader.MINIATURE_VIGNETTE（Environment 里没有暗角项）")
		if sm != null:
			all_ok = _ck(all_ok, is_equal_approx(
					float(sm.get_shader_parameter(&"u_strength")), mini.vignette_strength),
				"暗角强度应等于风格包的 vignette_strength")
			all_ok = _ck(all_ok, vl.layer < 10,
				"暗角层序号 %d 必须小于 UI 层（本项目 UI 在 10），否则会把按钮也压暗" % vl.layer)

	all_ok = _ck(all_ok, mini.stage_distance_hint > 62.0,
		"长焦必须换算出更远的相机距离（%.0f → %.0f），否则切风格包时画面会猛地凑近" % [
			62.0, mini.stage_distance_hint])

	# 第二遍：幂等。反复切风格包最容易在这里漏 —— 暗角越叠越黑、Environment 越挂越多，
	# 而 Godot 对重复的 WorldEnvironment 只认其中一个，于是"切了但没变化"且无报错。
	mini.apply_stage(host, cam, 62.0)
	all_ok = _ck(all_ok, host.find_children("*", "WorldEnvironment", true, false).size() == 1,
		"重复 apply_stage 不应新增第二个 WorldEnvironment")
	var vl2 = _vignette_of(host)
	all_ok = _ck(all_ok, vl2 != null and vl2 == vl and vl2.get_child_count() == 1,
		"重复 apply_stage 应复用同一个暗角层并清空重建，不叠层")

	# —— 主光：必须与 u_key_dir 对齐 ——
	#
	# 这条曾不存在，于是"实灯"与"色阶"各走各的：Godot 没有 LIGHT 内置量，
	# 色阶方向只由 u_key_dir 决定，而实灯是场景里手摆的，两者错开一道后
	# 画面上会出现"物体上一道硬边，别处亮暗还反着来" —— 不崩、不报错。
	var suns: Array = host.find_children("*", "DirectionalLight3D", true, false)
	all_ok = _ck(all_ok, suns.size() == 1,
		"apply_stage 已调用两遍，应恰好存在一盏主光（不新建重复的），实得 %d 盏" % suns.size())
	if suns.size() == 1:
		var sun := suns[0] as DirectionalLight3D
		## `DirectionalLight3D` 沿自身局部 **-Z** 出光，所以"光的来向"是局部 +Z。
		## 读 `transform`（局部）而不是 `global_transform`：本用例的 host 是临时
		## `Node3D`、**没有进场景树**，读 global 会报
		## `Condition "!is_inside_tree()" is true`，把断言变成一片噪音。
		## host 自身是单位变换，故此处局部 == 世界。
		var to_light := sun.transform.basis.z
		var mat: ShaderMaterial = mini.style.make_material(mini.palette)
		var shader_key: Vector3 = mat.get_shader_parameter(&"u_key_dir")
		all_ok = _ck(all_ok, to_light.dot(shader_key) > 0.999,
			"主光局部 +Z（光的来向）应与材质 u_key_dir 同向，实得点积 %s，灯 %s vs uniform %s" % [
				snappedf(to_light.dot(shader_key), 0.0001), to_light, shader_key])
		all_ok = _ck(all_ok, sun.shadow_enabled,
			"主光必须开阴影：关掉后 diffuse_toon 仍有明暗台阶，但没有任何投影")

	# —— frame_scale 的换算关系 ——
	all_ok = _ck(all_ok, absf(MiniatureStage.frame_scale(70.0) - 1.0) < 0.001,
		"frame_scale(自身基准 FOV) 应等于 1（不缩不放）")
	all_ok = _ck(all_ok, MiniatureStage.frame_scale(mini.camera_fov) > 1.5,
		"长焦 FOV 换出的后退倍率应 > 1.5，实得 %.2f" % MiniatureStage.frame_scale(mini.camera_fov))
	all_ok = _ck(all_ok, absf(MiniatureStage.frame_scale(35.0, 70.0)
			* MiniatureStage.frame_scale(70.0, 35.0) - 1.0) < 0.001,
		"frame_scale 的正反两次换算应互为倒数")

	host.free()
	return all_ok


## 取暗角层（按 [constant MiniatureStage.VIGNETTE_LAYER] 的固定名字）
static func _vignette_of(host: Node) -> CanvasLayer:
	var n := host.get_node_or_null(NodePath(MiniatureStage.VIGNETTE_LAYER))
	return n as CanvasLayer if n != null else null

## 失败项明细。返回值只有一个 bool 时，测试挂了只能去翻日志 ——
## 而日志往往已经被后续输出冲掉了。这里留一份可直接取用的清单。
static var failures: PackedStringArray = []

static func _ck(ok: bool, cond: bool, msg: String) -> bool:
	if not cond:
		failures.append(msg)
		print("[风格] 失败: " + msg)
	return ok and cond
