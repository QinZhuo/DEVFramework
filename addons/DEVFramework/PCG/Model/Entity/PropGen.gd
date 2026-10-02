@tool
@abstract class_name PropGen extends RefCounted
## 单体物体生成器契约 —— 只回答"这一个物体长什么样"
##
## ============================ 分层红线 ============================
## ✅ 本类**可以**知道：
##    自己的局部几何、局部尺寸、默认朝向、门在哪面、
##    几何该怎么平滑（primitives / op_smin）、要不要贴地
## ❌ 本类**不可以**知道：
##    自己在世界的哪个坐标、旁边有什么、道路在哪、地势高低
##    —— 任何世界上下文。位置 / 旋转 / 贴地 / 避让
##    一律由 [PropLayoutTool] 在**外层**施加。
## ==================================================================
##
## 由此得到的关键性质：**同一个 seed 在任何地方都烘焙出完全相同的单体**。
## 所以世界存档只需记 "哪个 seed 摆在哪个点、什么朝向"，
## 流式加载 / 分块重载时按需重烘焙，不必序列化网格。
##
## 子类只需实现两件事：
## [method local_bounds] —— 局部包围盒（框架据此开多大的场）
## [method build] —— 在局部空间的场里写出 SDF（真正造形状）
## 其余均可选覆写。造形状用 [method fill_shape] 或 SdfTool 的 sd_* 基元。
##
## 项目层示例（属于项目，不属于框架，放在项目 Scripts/ 下）：
## [codeblock]
## class_name ShopGen extends PropGen
##
## func local_bounds() -> AABB:
##     return AABB(-3, 0, -4, 6, 7, 8)          # 6×7×8 米店面
##
## func build(field: SdfField) -> void:
##     var body := func(p: Vector3) -> float:
##         return SdfTool.sd_box(p - Vector3(0, 3.5, 0), Vector3(3, 3.5, 4))
##     SdfTool.fill(field, body)
##
## func meta() -> Dictionary:
##     return {&"tag": "shop", &"surface_snap": true, &"face_dir": Vector3i(0, 0, 1)}
## [/codeblock]

## 通用烘焙参数（体素精度 / 等值面算法 / 画风）
var gen_def: PropGenDef

## 由 [method PropGenTool.make_rng] 派生 —— 一切随机都从这里取，保证 seed 可复现
var rng := RandomNumberGenerator.new()

## 生成流程用的临时场引用，由 [method generate] 填入。子类一般只用 [method fill_shape]
var _field: SdfField

## 体素产物的调色板档数上限。
## 体素网格的 data 是 PackedByteArray（0~255），但**分件色根本用不到 254 档** ——
## 真实分件（木 / 瓦 / 漆 / 纸…）通常二十几种到头。
## 另注意 254 是提取器内部的结构色占位，本上限刻意远离它。
##
## ============================ 为什么是 32 而不是 16 ============================
## [method ToonPaletteDef.to_array] 返回的长度**恒等于传入值**，不够时拿
## [member ToonPaletteDef.base] **补齐**。所以调色板比这个上限短不是"少几档"，
## 而是**多出来的部位被静默涂成主色** —— 第 17 号部位若在 16 档表里，
## 它和"没声明部位"的主体色一模一样，画面上完全看不出是配色表不够用。
## 用例四就踩过：树冠顶层要一个浅苔绿，加到第 17 格后渲染成亮黄（钳位兜底），
## 而日志里一行错都没有。把上限留出两倍余量，就是为了让这种静默降级更难发生。
const VOXEL_PALETTE_MAX := 32

## 局部包围盒（米）。框架据此分配场；建议 y 从 0 起算，便于布局层贴地。
@abstract func local_bounds() -> AABB

## 在局部空间的场里写出 SDF。场已按 [method local_bounds] + Def.margin 分配好。
@abstract func build(field: SdfField) -> void

## 逻辑占地（XZ，米）。默认取 local_bounds 的 XZ 尺寸；
## 若几何有挑檐 / 招牌等悬空部分，覆写为墙体尺寸可让避让更紧。
func footprint() -> Vector2:
	var b := local_bounds()
	return Vector2(b.size.x, b.size.z)

## 子类钩子：在**开场之前**把所有由 seed 决定的参数定死。
##
## 为什么必须单独开一个钩子：[method generate] 的顺序是
## prepare → local_bounds（据此开场）→ build（据此造形状），
## 而 seed 派生的随机在 [method rng] 就绪之后才可取。
## 若把 `depth = 2.5 * rng.randf_range(...)` 写在 [method build] 开头，
## local_bounds 已经用**未抖动**的尺寸开好了场 —— 抖动后几何可能溢出场边界，
## 等值面被截断（缺面），且这种缺面只在"seed 较大时"出现，极难排查。
## 默认空实现：确定性生成器（尺寸固定）不需要它。
func prepare() -> void:
	pass

## 生成器自报的属性（框架只透传，不解释）：
## [codeblock]
## &"tag"          分类标签（"shop" / "hospital" / "vehicle" …）
## &"surface_snap" 布局层是否把它压到地面
## &"face_dir"     正面朝向（局部空间 Vector3i），布局层据此对准道路
## &"wants_ground" 是否需要地面采样（房屋需要、悬浮物不需要）
## [/codeblock]
func meta() -> Dictionary:
	return {}

## 体素**部位分色**：声明"局部空间里哪一块用调色板第几号色"。
##
## 返回 `[{&"aabb": AABB（局部坐标）, &"index": int}, ...]`，按顺序首个命中即用其 index；
## 都没命中才回退"按归一化高度分层"。默认空 = 只有高度分层。
##
## ============================ 为什么需要这个钩子 ============================
## 没有它时，体素配色**只能按高度**分（见 [method VoxelExtractor.extract] 的 palette）。
## 这能表达"下浅上深"，但表达不了真正要区分的部位：门框要深棕、窗要暖黄发光、
## 招牌要红 —— 这些与高度无关，按高度上色会被涂成所在楼层的墙色。
## 而"哪块是门"恰恰是生成器独有的知识，框架不该也不必理解。
##
## [b]坐标系[/b]：局部空间，与 [method local_bounds] 和 [method fill_shape] 收到的 `p`
## **完全同一套**（[method PropGenDef.make_field] 的场原点是零向量），框架不做任何换算。
## y 从 0 起算时最省心。
##
## [b]调色板索引从 1 起[/b]：0 号留给未命中的部分（通常是主体色）。
## 索引不要超过 [constant VOXEL_PALETTE_MAX] - 1：超出的会被提取器钳到最后一位并
## 告警一次，而没进这张表的新颜色会被 [method ToonPaletteDef.to_array] 拿主色顶替 ——
## 两者都是"不崩、但颜色不对"。
func voxel_regions() -> Array:
	return []

## 用形状函数一次性填充局部场 —— build() 里最常用的入口。
## [param fn] 签名 func(local_pos: Vector3) -> float，返回有符号距离（负 = 实心）。
func fill_shape(fn: Callable) -> void:
	if fn == null or _field == null:
		return
	SdfTool.fill(_field, fn)

## 完整烘焙：局部 SDF → 局部网格 + 元信息。全程不涉及任何世界坐标。
func generate() -> PropBuild:
	var gd: PropGenDef = gen_def if gen_def else PropGenDef.new()
	prepare()
	_field = gd.make_field(local_bounds())
	build(_field)

	if gd.sharpen > 0.0:
		SdfTool.harden(_field, gd.sharpen)
		SdfTool.refresh_band_bounds(_field)   ## 硬边化改写了 data，窄带缓存失效

	var m := MeshExtractor.extract(_field, gd.algo, {
		&"dc_eps": gd.dc_eps,
		&"sharp_normal": gd.sharp_normal,
	})

	## —— 产物 2/2：体素网格 ——
	## 与上面的 mesh **共用这一次场烘焙**，两者必然同源：
	## same seed 下不会出现"低多边形版与体素版形状不一致"这种事。
	## 位置很关键：必须排在 harden 之后（硬边化改写了 data，晚于它会拿到未量化的场），
	## 也必须早于 `_field = null`（场一丢就没得提了）。
	var vox: SdfVoxel = null
	## 两个开关任一为正就产体素。只认 voxel_res 会让"只填 voxel_cell"的用法
	## （[method DioramaRecipe.voxel_cell] 推荐的填法）安静地拿到空体素产物 ——
	## 网格照常出图，只是体素那一份没了，不报任何错。
	if gd.voxel_res > 0 or gd.voxel_cell > 0.0:
		var vopts := {}
		if gd.voxel_palette != null:
			vopts[&"palette"] = gd.voxel_palette.to_array(VOXEL_PALETTE_MAX)
		## 部位分色：生成器自报"哪块是什么颜色"，原样交给提取器。
		## 默认空数组 = 纯高度分层，行为与既有生成器完全一致。
		##
		## 无需坐标换算：[method PropGenDef.make_field] 建场时 origin 传的是 Vector3.ZERO，
		## 而 [method SdfField.get_chunk] 按 `origin + ck * chunk_size * voxel_size` 算块原点，
		## 所以提取器遍历出来的坐标与 [method fill_shape] 收到的 p、与 [method local_bounds]
		## **三者同源**，都是生成器局部空间。margin 只是把场分配得更大，不参与坐标。
		var regs := voxel_regions()
		if not regs.is_empty():
			var conv := []
			for r in regs:
				var reg: Dictionary = r
				var box: Variant = reg.get(&"aabb", null)
				if box is AABB:
					conv.append({&"aabb": box, &"index": int(reg.get(&"index", 0))})
			if not conv.is_empty():
				vopts[&"tint_regions"] = conv
		## 显式给的物理边长压过 res —— 见 [member PropGenDef.voxel_cell]。
		if gd.voxel_cell > 0.0:
			vopts[&"cell"] = gd.voxel_cell
		vox = VoxelExtractor.extract(_field, gd.voxel_res, vopts)
	_field = null

	var b := PropBuild.new()
	b.mesh = m
	b.voxel = vox
	b.bounds = m.local_aabb if not m.is_empty() else local_bounds()
	b.footprint = footprint()
	b.meta = meta()
	return b

## 快速换 seed 重烘焙（同一生成器实例复用，避免重复分配）
func rebake(p_seed: int) -> PropBuild:
	rng = PropGenTool.make_rng(p_seed)
	return generate()
