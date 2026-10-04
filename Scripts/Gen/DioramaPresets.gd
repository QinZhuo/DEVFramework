@tool
class_name DioramaPresets
extends RefCounted
## 用例四「体素面包店街角」的内容包 —— 9 个生成器 + 落位配方 + 氛围灯
##
## ============================ 这一层放什么、不放什么 ============================
## [DioramaDef] / [DioramaRecipe] 是**框架层**：只认识"主体 / 环境 / 道具"、
## "中心 / 环带 / 背板"、"烘焙精度多少"。它不认识面包店。
## 本文件是**项目层**：把 [code]Scripts/Gen/Diorama/[/code] 里的 9 个生成器
## 装进那套空壳，并给每个生成器安排落位。
## 换句话说，[DioramaBuilder] 负责"怎么摆"，本文件负责"摆什么、摆哪"。
##
## ============================ 落位是怎么排出来的 ============================
## 底座 10×10（[constant VoxelSquareBaseGen.HALF] 5.0）⇒ 底座半径 5.0。
## [DioramaBuilder] 的越界判定是 `底座半径 ×(1+overhang) − 自身体素外接半径`，
## 代入后各类道具的可用半径上限在 **3.0 ~ 5.2** 之间，于是：
## [codeblock]
##   背板弧 90°(+Z)  radius 3.4   邻栋 ×2     45° / 135°   围出"街角"的墙
##   中心   radius 1.1 角 270°   面包店      正面朝 -Z   ← 镜头侧，前景主体
##   环带2  radius 4.0 环带相位 190° 小树 ×2   190° / 10°  两侧
##   环带1  radius 3.6 环带相位 230° 路灯 ×2   230° / 310° 门两侧
##   环带0  radius 3.0~4.5      长椅/邮筒/展示架/顾客 ×5   门前与两侧
## [/codeblock]
## 面包店是唯一需要**显式 radius** 的配方：它占地 3.56×4.3、外接半径 2.79，
## 若按 [code]Layout.CENTER[/code] 的默认半径 0 落位，中心就正对着背板弧，
## 邻栋会被 relax 顶着往前推、最后三样东西挤成一团。往前挪 1.1 米（朝镜头）之后，
## "前景店铺 + 后景围墙"的纵深才出来。
##
## ============================ 为什么全场只给 voxel_cell ============================
## 体素方块的**物理边长**是一个物理量，必须直接指定。
## 换成"最长边切几格"（voxel_res）就一定会漂：体素网格的定位盒是窄带盒，
## 比模型宽约 2×band（默认 3×voxel_size = 0.36 米，两侧就是 0.72 米），
## 于是 7.9 米的面包店方块偏大 9%、1.16 米的长椅偏大 66% —— 同一场景里方块差一倍，
## 而所有中间数字看起来都正常。详见 [member DioramaRecipe.voxel_cell]。

# ============================================================== 布局常量

## 底座 10×10 ⇒ 半径 5.0。道具环带从 2.6 起排，最大用到 4.0。
const INNER_RADIUS := 2.6
const RING_STEP := 0.7

## 全场统一的目标体素边长（米）。见文件头说明。
##
## 定 0.12 而不是"看起来更方"的 0.2，是量出来的：0.2 米下一个 1.55 米高、
## 0.54 米宽的顾客只占 2~3 格宽，全身上下文数完只有 **16 个体素**；
## 邮筒 12 个、路灯 68 个 —— 这不是"体素风格"，这是"掉渣"。
## 收到 0.12 米（顾客约 90 块、邮筒约 70 块）才读得出形状，
## 代价是总块数约 12 万、三角面约 12 万，都在演示场景可接受的量级内。
const CELL := 0.12

## 用例二（中世纪村庄）的体素边长。定 0.16 有两个理由：
##
## ① 低模要的是"块面大、棱线少"。0.12 会把一件 3.8 米高的井切成 28×33×28 ≈ 2.6 万格，
##    侧面那些台阶因为太密而重新连成一片 —— 反而读不出"低多边形"。
## ② **烘焙耗时与格数成正比**（实测每格约 1 ms，那是 `fill()` 逐格回调 lambda 的成本）。
##    0.16 时全场约 9 万格 ⇒ 2 分半；0.20 压到 6 成 ⇒ 一分半。
##    这个数字是"看得清"与"等得起"的交点，不是随便给的。
const VILLAGE_CELL := 0.20

## 底座单独用更粗的格子：它是全场最大的一块（14.2×2.0×14.2）。
## 按 0.20 切是 73×12×73 ≈ 6.4 万格，光它一件就要烘一分多钟；
## 0.34 压到 1.3 万格，而岩石切面的层厚是 0.28 —— 仍够分出一级台阶，不至于糊成斜面。
const VILLAGE_BASE_CELL := 0.34

## 用例二的生成器目录。与文件末尾的 [constant GEN_DIR]（用例四）分开：
## 两幅画各占一个子目录，避免 20 多个生成器平铺在一层里。
const GEN_DIR_MED := "res://Scripts/Gen/Diorama/Medieval/"
const GEN_DIR_STEAM := "res://Scripts/Gen/Diorama/Steampunk/"

# ============================================================== 预设表

## 预设表。`StringName → 一幅 diorama 的全部内容`。
##
## 除了 [method DioramaBuilder.build] 要的 `def` / `recipes`，还带三样**演示层**的东西：
## [codeblock]
##   &"skin"  : DioramaSkin     —— 这一幅的配色契约（逐索引取色的唯一出口）
##   &"style" : ToonStyleDef    —— 这一幅的画风（含 PBR 参数 / 雾 / 描边，见各预设说明）
##   &"view"  : Dictionary      —— 取景：dist / look / pitch / yaw
##   &"env"   : Dictionary      —— 曝光 / 对比 / 饱和 / 长焦 / 景深 / 背景色
## [/codeblock]
## 这三样**框架层一概不认识**：[DioramaBuilder] 只吃 def 与 recipes。
## 放在这里是因为它们都是"这一幅画长什么样"的内容判断。
##
## 用 [method DioramaBuilder.build] 时只取 def 与 recipes：
## [codeblock]
## var p := DioramaPresets.presets()[&"voxel_bakery"]
## var b := DioramaBuilder.build(p[&"def"], p[&"recipes"], 42)
## print(b.story(), b.validate())
## [/codeblock]
static func presets() -> Dictionary:
	return {
		&"voxel_bakery": {
			&"def": _bakery_def(),
			&"recipes": _bakery_recipes(),
			&"skin": VoxelSkinPack.new(),
			&"style": ToonStyleDef.presets()[&"miniature_diorama"],
			&"cell": CELL,
			&"view": {&"dist": 19.0, &"look": Vector3(0.0, 3.0, -0.8),
				&"pitch": 0.62, &"yaw": PI},
			&"env": {&"exposure": 0.75, &"contrast": 1.06, &"saturation": 1.14,
				&"fov": 28.0, &"dof": 0.55, &"backdrop": Color(0.62, 0.66, 0.76)},
		},
		&"lowpoly_village": {
			&"def": _village_def(),
			&"recipes": _village_recipes(),
			&"skin": MedievalSkin.new(),
			&"style": _lowpoly_style(),
			&"cell": VILLAGE_CELL,
			## 岛外接 14.4 米、最高的是塔顶 5.0 米 ⇒ 取景距离 23 米、视点抬到 2.6 米。
			## 用面包店那组（19 米 / y=3.0）会让这座矮村子只占画面中间一小块，
			## 四周全是背景 —— 而"展示底座完整入画"正是微缩感的识别特征。
			&"view": {&"dist": 23.0, &"look": Vector3(0.0, 2.6, -0.4),
				&"pitch": 0.58, &"yaw": PI},
			&"env": {&"exposure": 0.88, &"contrast": 1.04, &"saturation": 1.10,
				&"fov": 30.0, &"dof": 0.50, &"backdrop": Color(0.52, 0.58, 0.68)},
		},
		&"steam_dock": {
			&"def": _steam_def(),
			&"recipes": _steam_recipes(),
			&"skin": SteamSkin.new(),
			&"style": _steam_style(),
			&"cell": STEAM_CELL,
			## 台面 14.5×10.5、最高的是锅炉安全阀 2.0 米 ⇒ 24 米、视点 2.4 米。
			## 背景压到很暗：Color 是**线性**值，0.045 转显示才约 0.24 的暗灰蓝。
			## 直接写 0.24 看着"暗"，实际转 sRGB 后是 0.53 的中灰，整幅画会被抬亮。
			## 黄铜是暖亮色，深冷的底子才把它衬出来 ——
			## 换浅背景的话整幅画会"糊在雾里"，金属的分量全丢。
			&"view": {&"dist": 24.0, &"look": Vector3(0.0, 2.4, -0.6),
				&"pitch": 0.55, &"yaw": PI},
			&"env": {&"exposure": 0.78, &"contrast": 1.10, &"saturation": 1.15,
				&"fov": 30.0, &"dof": 0.50, &"backdrop": Color(0.045, 0.048, 0.062)},
		},
	}


# ============================================================== DioramaDef

## 展示底座 + 簇式布局参数。
##
## [member DioramaDef.voxel_grid_snap] 刻意等于 [constant CELL]：
## 每个单体的体素格点锚在**它自己的局部原点**上，所以哪怕全场同一个体素边长，
## 相邻两件物体的体素也会各算各的、叠加处出现半格错位。吸附到 CELL 的整数倍后
## 全场落在同一套格点上，这正是"统一方块"能被看出来的前提。
static func _bakery_def() -> DioramaDef:
	var d := DioramaDef.new()
	## 底座本身也是一个 [PropGen]：它吃同一条 SDF → 双产物管线，能出体素，
	## 所以"边缘由统一正方体单元构成"这条验收项对底座同样成立。
	d.base_gen = load("res://Scripts/Gen/Diorama/VoxelSquareBaseGen.gd")
	## 底座烘焙参数。同样只给 CELL：底座 10 米 / 0.12 米 ≈ 84 格，由提取器自己切。
	var bd := PropGenDef.new()
	bd.voxel_size = 0.12
	bd.margin = 0.3
	bd.algo = MeshExtractor.Algo.DUAL_CONTOURING
	bd.voxel_cell = CELL
	bd.voxel_palette = VoxelSkin.palette()
	d.base_def = bd
	d.base_top = 0.0        ## VoxelSquareBaseGen 的顶面严格落在 y = 0
	d.constrain_to_base = true
	d.overhang = 0.15

	d.inner_radius = INNER_RADIUS
	d.ring_step = RING_STEP
	## 镜头在 -Z 侧 ⇒ 背板弧心放 +Z（90°），弧张 90° 只围后侧，
	## 留出 -Z 整个开口给镜头 —— 张角一旦接近 180，主体就被半圈墙围死。
	d.backdrop_angle = 90.0
	d.backdrop_arc = 90.0
	d.ground_step = 1.0
	d.shrink = 0.90
	d.relax_iterations = 28
	d.voxel_grid_snap = CELL
	d.accent_lights = _accent_lights()
	return d


## 氛围灯：窗里的暖光 + 两盏路灯。
##
## [member DioramaDef.accent_lights] 的 [code]offset[/code] 是**相对底座中心的水平偏移**，
## 写的是 (x, 0, z) —— y 由 [code]height[/code] 单独给。数值与上面配方表里的
## radius/angle 对得上（面包店落在 (0, -1.1)，路灯落在 (±2.4, -2.8)）。
##
## 注意：**框架层没有任何代码消费这个数组**（[DioramaDef] 只负责声明），
## 真正把它变成 [OmniLight3D] 的是演示场景（见 `Scenes/PCG/PCGDioramaDemo.gd`）。
## 这与 [member DioramaDef.base_gen] 是同一个分工：Def 声明"要什么"，
## 场景负责"摆进引擎"。灯只做局部外溢；整幅画面的雾 / 暗角 / 曝光由
## [SceneStylePack] 管，两者是正交的。
static func _accent_lights() -> Array:
	return [
		## 面包店窗口：暖黄、范围大、位置在一层窗台高度
		{&"color": Color(1.00, 0.84, 0.55), &"energy": 1.7, &"radius": 2.6,
			&"offset": Vector3(0.0, 0.0, -1.1), &"height": 1.9, &"flicker": 0.0},
		## 门口遮阳棚下的一小团暖光，把前景道具从冷灰石地面上托起来
		{&"color": Color(1.00, 0.90, 0.72), &"energy": 0.9, &"radius": 1.8,
			&"offset": Vector3(0.0, 0.0, -4.0), &"height": 1.5, &"flicker": 0.0},
		## 两盏路灯
		{&"color": Color(1.00, 0.93, 0.68), &"energy": 1.3, &"radius": 2.0,
			&"offset": Vector3(-2.4, 0.0, -2.8), &"height": 2.9, &"flicker": 0.05},
		{&"color": Color(1.00, 0.93, 0.68), &"energy": 1.3, &"radius": 2.0,
			&"offset": Vector3(2.4, 0.0, -2.8), &"height": 2.9, &"flicker": 0.05},
	]


# ============================================================== 配方表

## 生成器脚本目录。9 个脚本都在这里，没有第二处路径。
const GEN_DIR := "res://Scripts/Gen/Diorama/"


static func _bakery_recipes() -> Array:
	return [
		## —— 主体 ——
		_recipe("bakery", "BakeryShopGen.gd", 1, DioramaRecipe.Role.SUBJECT, {
			"layout": DioramaRecipe.Layout.CENTER,
			## 显式 radius：见文件头。默认的 0 会让它正对背板弧、与邻栋挤成一团。
			"radius": 1.1, "angle": 270.0, "radius_jitter": 0.0, "angle_jitter": 0.0,
			## OUTWARD 而不是 CENTER：主体在 -Z 侧（镜头这一侧），
			## "正面朝圆心"等于**背对镜头**。朝外才是店铺该有的朝向。
			## face_dir 由生成器自报（BakeryShopGen 正面朝 +Z），框架不猜。
			"facing": DioramaRecipe.Facing.OUTWARD,
			"kind_id": 1,
		}),

		## —— 环境：邻栋围出"街角"的两面墙 ——
		## count=2 会在 backdrop_arc 上均分（含两端）⇒ 45° 与 135°，
		## 两栋之间留出 90° 的缺口给主体，正好是一个"角"。
		_recipe("townhouse", "TownhouseGen.gd", 2, DioramaRecipe.Role.ENV, {
			"layout": DioramaRecipe.Layout.BACKDROP,
			"radius": 3.4, "angle_jitter": 2.0, "radius_jitter": 0.05,
			"facing": DioramaRecipe.Facing.CENTER,
			"kind_id": 2,
		}),
		_recipe("tree", "VoxelTreeGen.gd", 2, DioramaRecipe.Role.ENV, {
			"layout": DioramaRecipe.Layout.RING, "band": 2,
			## angle 是**相位**：两棵落在 190° 与 10°（相差 180°），即主体左右两侧。
			## 早先把它当"所有实例的同一个角"，两棵树会叠在同一个坐标上，
			## relax 再怎么推也只在原地打转 —— 这是 RING 落位最容易踩的坑。
			"angle": 190.0, "angle_jitter": 4.0, "radius_jitter": 0.15,
			"facing": DioramaRecipe.Facing.CENTER,
			"kind_id": 3,
		}),
		_recipe("lamp", "StreetLampGen.gd", 2, DioramaRecipe.Role.ENV, {
			"layout": DioramaRecipe.Layout.RING, "band": 1,
			"angle": 230.0, "angle_jitter": 3.0, "radius_jitter": 0.08,
			## TANGENT：路灯顺着街道走才自然。半径 3.6 是刻意量过的 ——
			## 面包店占地 x∈[-1.78,1.78]，路灯再往内就会插进墙里。
			"radius": 3.6,
			"facing": DioramaRecipe.Facing.TANGENT,
			"kind_id": 4,
		}),

		## —— 道具：街角该有的生活痕迹 ——
		_recipe("rack", "DisplayRackGen.gd", 1, DioramaRecipe.Role.PROP, {
			"layout": DioramaRecipe.Layout.RING,
			## 半径 4.1：面包店的遮阳棚外伸到局部 z=2.6，朝 -Z 摆时世界 z≈-3.7，
			## 展示架必须落在它**前面**（z 更负）才看得见，否则被自己的雨棚挡住。
			"radius": 4.1, "angle": 270.0, "radius_jitter": 0.0, "angle_jitter": 0.0,
			"facing": DioramaRecipe.Facing.OUTWARD,
			"kind_id": 5,
		}),
		_recipe("bench", "BenchGen.gd", 1, DioramaRecipe.Role.PROP, {
			"layout": DioramaRecipe.Layout.RING, "band": 0,
			"radius": 3.0, "angle": 330.0, "angle_jitter": 4.0,
			"facing": DioramaRecipe.Facing.TANGENT,
			"kind_id": 6,
		}),
		_recipe("mailbox", "MailboxGen.gd", 1, DioramaRecipe.Role.PROP, {
			"layout": DioramaRecipe.Layout.RING, "band": 0,
			"radius": 2.9, "angle": 200.0, "angle_jitter": 3.0,
			"facing": DioramaRecipe.Facing.TANGENT,
			"kind_id": 7,
		}),
		## 两名顾客拆成两条配方而不是一条 count=2：
		## RING 落位按 count 均分整周（相差 180°），两人会被分到街角的两头而不是门前；
		## 而"两个一模一样的立人"本来就该由 [method CustomerGen.prepare] 的
		## 衣色 / 抬手随机化来区分，拆开还能各自指定站位。
		_recipe("customer_a", "CustomerGen.gd", 1, DioramaRecipe.Role.PROP, {
			"layout": DioramaRecipe.Layout.RING, "band": 0,
			"radius": 4.3, "angle": 250.0, "angle_jitter": 2.0,
			"facing": DioramaRecipe.Facing.CENTER,
			"kind_id": 8,
		}),
		_recipe("customer_b", "CustomerGen.gd", 1, DioramaRecipe.Role.PROP, {
			"layout": DioramaRecipe.Layout.RING, "band": 0,
			"radius": 4.5, "angle": 290.0, "angle_jitter": 2.0,
			"facing": DioramaRecipe.Facing.CENTER,
			"kind_id": 9,
		}),
	]


## 装配一条配方。
##
## 统一在这里灌 [constant CELL]（[member DioramaRecipe.voxel_cell]）与
## [member DioramaRecipe.voxel_palette]：前者保证全场方块边长一致，
## 后者只是给提取器一份"按高度分层的兜底色板"—— 本包的 9 个生成器都带
## 覆盖全包围盒的兜底区（见 [VoxelSkin] 文件头），这份色板实际不会被读到，
## 但填上它意味着"哪天有人删了兜底区，画面退化成按高度刷条纹"这件事是可预期的。
static func _recipe(tag: String, gen_file: String, count: int, role: int,
		opt: Dictionary) -> DioramaRecipe:
	return _recipe_in(GEN_DIR, VoxelSkinPack.new(), CELL, tag, gen_file, count, role, opt)


## 装配一条配方（通用版）。[param dir] 决定画、[param skin] 决定色板、
## [param cell] 决定全场统一的体素边长 —— 三者都是"整幅画"的属性，
## 所以由预设统一灌入，单个配方不填。
##
## [member DioramaRecipe.voxel_size] 显式写成与 [param cell] 同值：
## 让"网格产物精度"与"体素产物精度"在同一个文件里一眼能对照，
## 而不是一个走默认值、一个走 cell（那样改一处会只改一半，且不报错）。
static func _recipe_in(dir: String, skin: DioramaSkin, cell: float, tag: String,
		gen_file: String, count: int, role: int, opt: Dictionary) -> DioramaRecipe:
	var r := DioramaRecipe.new()
	r.tag = tag
	r.gen_script = load(dir + gen_file) as Script
	r.count = count
	r.role = role
	r.voxel_size = cell
	r.sharp_normal = true
	r.voxel_cell = cell
	r.voxel_palette = skin.palette()
	for k in opt.keys():
		r.set(StringName(k), opt[k])
	return r


# ============================================================== 用例二 · 中世纪村庄广场

## 布局：底座六边形外接 7.0、**内切 6.06**（[member HexIslandBaseGen.R]）。
##
## ## 与方形底座的差别：可用半径随方位角变化
## 六个角的方向有 7.0，六条边的中点方向只有 **6.06**。所以这里一律按 6.06 排。
##
## ## 为什么必须自己按半径算，不能指望 `constrain_to_base`
## 那条越界判定是**逐轴**的（|x|+半宽 vs `base_half_extent`），对六边形完全失效：
## AABB 半尺寸是 6.1，可六边形在边中点方向只有 5.20 ——
## 一件落在 30° 方向、半径 4.4 的木屋，逐轴判是"没越界"，实际已经悬空了 0.8 米。
## 框架按外接半径判不出来，于是**这里必须自己留余量**，且余量要给 relax 用：
## relax 只解互相穿插，它不知道岛边在哪，被推出去的单体不会有任何报错。
## 下面的 radius 都是"设计值"，实测 relax 还会再往外推 0.5~1.5 米，
## 所以真正的判据是 **设计值 + 自身半对角 + 1.5 ≤ 6.06**：
##
## · 木屋 radius 2.55 ＋半对角 2.05 ＋1.5 = 6.10（落在 30°/150°，边中点方向）
## · 塔 radius 2.80 ＋半对角 1.41 ＋1.5 = 5.71
## · 树（band 2 = 2.60）＋半宽 0.80 ＋1.5 = 4.90
## · 桥 radius 2.25 ＋半对角 1.89 ＋1.5 = 5.64
const VILLAGE_INNER := 1.7
const VILLAGE_RING_STEP := 0.45

static func _village_def() -> DioramaDef:
	var d := DioramaDef.new()
	d.base_gen = load(GEN_DIR_MED + "HexIslandBaseGen.gd")
	var bd := PropGenDef.new()
	bd.voxel_size = VILLAGE_BASE_CELL
	## margin 0.2 而不是配方默认的 0.4：底座是"一整块"，没有需要外扩的细节，
	## 而底座的格数是全场最大的，省下的 0.2 米在三个轴上各少吃两圈格。
	bd.margin = 0.2
	bd.algo = MeshExtractor.Algo.DUAL_CONTOURING
	bd.voxel_cell = VILLAGE_BASE_CELL
	bd.voxel_palette = MedievalSkin.new().palette()
	d.base_def = bd
	d.base_top = 0.0
	d.constrain_to_base = true
	d.overhang = 0.12

	d.inner_radius = VILLAGE_INNER
	d.ring_step = VILLAGE_RING_STEP
	## 镜头在 -Z 侧 ⇒ 背板弧心放 +Z（90°）。弧张 120°：这座村子有三件靠后
	## （屋 / 塔 / 屋），窄了会挤成一排、被 relax 一路推到岛外。
	## 张到 120° 后两栋屋落在 30° 与 150° —— 恰好是六边形的两条边中点方向，
	## 也就是**可用半径最小**的方向，所以它们的 radius 必须按 4.68 而不是 5.4 算。
	d.backdrop_angle = 90.0
	d.backdrop_arc = 120.0
	d.ground_step = 1.0
	## shrink 0.90 → 0.82：这个系数是"避让时把 footprint 缩掉多少再判重叠"。
	## 0.90 时每件只肯让出一成，十件挤在岛上会被 relax 一路推到岛边 ——
	## 实测那次木屋中心被推到半径 4.39（外缘 5.97，半栋悬空）。
	## 0.82 让每件肯让两成，推开量随之降到四成左右。
	d.shrink = 0.82
	## 迭代 24 → 16：relax 每轮都把重叠往"远离彼此"的方向推，推得太彻底会让
	## 整圈物件均匀外扩到岛边（实测 24 轮时桥从 2.45 被推到 4.40）。
	## 16 轮足够拆开真正的穿插，又不会把构图撑成一个空心的环。
	d.relax_iterations = 16
	d.voxel_grid_snap = VILLAGE_CELL
	d.accent_lights = _village_lights()
	return d


## 氛围灯：篝火（暖橙、闪）/ 木屋窗（暖黄）/ 塔顶（冷白）。
##
## 三处灯的 [code]offset[/code] 都是**照抄配方表算出来的落位**：
## · 篝火 = props 组（radius 2.05、angle 120° ⇒ 世界 (−1.03, 1.78)），
##   组内篝火还偏了约 0.9 米，所以 radius 给到 2.6 覆盖这个误差。
## · 两扇窗 = 两栋木屋（radius 2.55、angle 30°/150° ⇒ (±2.21, 1.28)）。
## · 塔顶 = 塔（radius 2.80、angle 90° ⇒ (0, 2.80)）。
##
## 灯位对不准**不会报错**，只会让火堆看起来"不发光"、窗看起来"没点灯"——
## 而这恰恰是这座村子唯一的三处叙事光，抄一遍数字是值得的。
static func _village_lights() -> Array:
	return [
		{&"color": Color(1.00, 0.62, 0.30), &"energy": 2.2, &"radius": 2.6,
			&"offset": Vector3(-1.03, 0.0, 1.78), &"height": 0.55, &"flicker": 0.35},
		{&"color": Color(1.00, 0.85, 0.58), &"energy": 1.3, &"radius": 2.4,
			&"offset": Vector3(-2.21, 0.0, 1.28), &"height": 1.90, &"flicker": 0.0},
		{&"color": Color(1.00, 0.85, 0.58), &"energy": 1.1, &"radius": 2.2,
			&"offset": Vector3(2.21, 0.0, 1.28), &"height": 1.90, &"flicker": 0.0},
		{&"color": Color(0.85, 0.92, 1.00), &"energy": 0.8, &"radius": 2.0,
			&"offset": Vector3(0.0, 0.0, 2.80), &"height": 4.60, &"flicker": 0.0},
	]


## 低多边形 JRPG 画风。**不走框架内置的 6 套**，在这里手工装配，理由有二：
##
## ① `anime_flat`（roughen 1.0）是给"远景山体"的：它把一切都压成大方块，
##    1.7 米的村民会直接变成一根柱子。这里 roughen 取 0.55 ——
##    够块面，又留得住"塔是八棱、屋是两层"这种中等尺度的造型信息。
## ② 框架预设的 `fog_density` 大多按"街景 / 桌面"标定，而本场景的相机被
##    长焦推到 45 米外（见 [method _village_def] 同族的说明）：
##    雾按距相机算，0.02 在那个距离上是 60% 洗白 —— 必须自己给一个 0.003。
##
## 描边取 0.008（比用例四的 0.005 略粗）：低模的块面比 0.12 的体素大，
## 边太细会在台阶密集处糊掉，而"棱线清晰"正是用例二的验收项。
static func _lowpoly_style() -> ToonStyleDef:
	var s := ToonStyleDef.new()
	s.title = "低多边形 JRPG"
	s.resource_name = s.title
	s.roughen = 0.55
	s.voxel_size = VILLAGE_CELL
	s.bands = 2
	s.band_softness = 0.03
	s.shadow_tint = Color(0.50, 0.48, 0.68)
	s.shadow_floor = 0.30
	s.key_light_color = Color(1.0, 0.96, 0.90)
	s.shadow_tint_follow = 0.35
	s.key_light_dir = Vector3(-0.28, 0.90, -0.34)
	s.fill_color = Color(0.72, 0.80, 1.0)
	s.fill_strength = 0.28
	s.outline_mode = ToonStyleDef.OutlineMode.INVERTED_HULL
	s.outline_width = 0.008
	s.outline_color = Color(0.24, 0.20, 0.28, 1.0)
	s.rim_strength = 0.55
	s.rim_power = 2.6
	s.ambient = Color(0.74, 0.78, 0.88)
	s.ambient_energy = 0.45
	s.fog_color = Color(0.66, 0.72, 0.82)
	s.fog_density = 0.003
	return s


static func _med(tag: String, gen_file: String, count: int, role: int,
		opt: Dictionary) -> DioramaRecipe:
	return _recipe_in(GEN_DIR_MED, MedievalSkin.new(), VILLAGE_CELL,
		tag, gen_file, count, role, opt)


static func _village_recipes() -> Array:
	return [
		## —— 主体：广场中央的石井 ——
		## radius 0.9 而不是 0：石井若正落在圆心，三件靠后的建筑
		## （两栋屋 + 一座塔）会把它围成一个"井在院子里"的构图，
		## 而用例要的是"井在广场正中、四周留出走动的余地"。
		## 往镜头侧（-Z，angle 270）挪 0.9 米，前景才空得出来。
		_med("well", "StoneWellGen.gd", 1, DioramaRecipe.Role.SUBJECT, {
			"layout": DioramaRecipe.Layout.CENTER,
			"radius": 0.9, "angle": 270.0, "radius_jitter": 0.0, "angle_jitter": 0.0,
			## OUTWARD：石井的正面（辘轳那一侧）朝圆心外侧 = 朝镜头。
			## CENTER 会让它背对镜头，且**没有任何报错**。
			"facing": DioramaRecipe.Facing.OUTWARD,
			"kind_id": 1,
		}),

		## —— 环境：靠后的两栋木屋 + 一座塔 ——
		## BACKDROP 上 count=2 均分含两端 ⇒ 35° 与 145°，塔（count=1）落在弧心 90°，
		## 三者间隔 55°，是"错落"而不是"排队"。
		_med("house", "TimberHouseGen.gd", 2, DioramaRecipe.Role.ENV, {
			"layout": DioramaRecipe.Layout.BACKDROP,
			"radius": 2.55, "angle_jitter": 2.0, "radius_jitter": 0.04,
			"facing": DioramaRecipe.Facing.CENTER,
			"kind_id": 2,
		}),
		_med("tower", "WatchTowerGen.gd", 1, DioramaRecipe.Role.ENV, {
			"layout": DioramaRecipe.Layout.BACKDROP,
			## 比木屋更靠后 0.20 米：塔身细、占地小，退一点不会撞，
			## 但它的锥顶最高（5.0 米），退后才能在画面上方留出天际线。
			"radius": 2.80, "angle_jitter": 0.0, "radius_jitter": 0.0,
			"facing": DioramaRecipe.Facing.CENTER,
			"kind_id": 3,
		}),
		## 两棵而不是三棵：树冠直径 1.9 米，是岛上第二占地的东西，
		## 三棵加上两栋屋与塔就顶到内切圆了（见 [constant VILLAGE_INNER] 的算式）。
		_med("tree", "StylizedTreeGen.gd", 2, DioramaRecipe.Role.ENV, {
			## angle 是**相位**：两棵落在 40° / 220°（相差 180°），分站广场两侧。
			## 当成"所有实例的同一个角"的话两棵会叠在一个坐标上，
			## relax 只在原地打转 —— 这是 RING 落位最容易踩的坑。
			"layout": DioramaRecipe.Layout.RING, "band": 2,
			"angle": 40.0, "angle_jitter": 5.0, "radius_jitter": 0.12,
			"facing": DioramaRecipe.Facing.CENTER,
			"kind_id": 4,
		}),
		_med("bridge", "PlankBridgeGen.gd", 1, DioramaRecipe.Role.ENV, {
			## TANGENT：桥的轴向沿切线，小溪就横着切过广场外圈，
			## 不会从中央的石井身上穿过去（径向摆法一定会穿）。
			"layout": DioramaRecipe.Layout.RING,
			"radius": 2.25, "angle": 210.0, "radius_jitter": 0.0, "angle_jitter": 0.0,
			"facing": DioramaRecipe.Facing.TANGENT,
			"kind_id": 5,
		}),

		## —— 道具 ——
		_med("villager", "VillagerGen.gd", 3, DioramaRecipe.Role.PROP, {
			## band 0 = 2.0 米，围着井站 —— "广场"这个词就是由这三个人撑起来的。
			"layout": DioramaRecipe.Layout.RING, "band": 0,
			"angle": 60.0, "angle_jitter": 6.0, "radius_jitter": 0.18,
			"facing": DioramaRecipe.Facing.CENTER,
			"kind_id": 6,
		}),
		_med("props", "VillagePropsGen.gd", 1, DioramaRecipe.Role.PROP, {
			## 抖动全关：氛围灯的 offset 是按这个落位算的（见 [method _village_lights]），
			## 抖一下灯就对不上，而"灯对不上"的表现只是火堆不发光。
			"layout": DioramaRecipe.Layout.RING,
			"radius": 2.05, "angle": 120.0, "radius_jitter": 0.0, "angle_jitter": 0.0,
			"facing": DioramaRecipe.Facing.OUTWARD,
			"kind_id": 7,
		}),
	]


# ============================================================== 用例五 · 飞艇码头工坊

## 台面 14×10（[member DockBaseGen.HALF_X] / [constant HALF_Z]）。
## 与用例二的六边形不同，**矩形台面的逐轴越界判定是有效的**：
## 越界的单体会被直接剔除（画面上"少一件"），而不会被悄悄摆到悬空的位置。
## 于是这里的余量可以给得更紧，代价是要盯住日志里的件数。
const STEAM_CELL := 0.16        ## 比用例二的 0.20 细：用例五的验收项写着"高度细节"
const STEAM_BASE_CELL := 0.30   ## 底座最大，单独给粗格子

static func _steam_def() -> DioramaDef:
	var d := DioramaDef.new()
	d.base_gen = load(GEN_DIR_STEAM + "DockBaseGen.gd")
	var bd := PropGenDef.new()
	bd.voxel_size = STEAM_BASE_CELL
	bd.margin = 0.2
	bd.algo = MeshExtractor.Algo.DUAL_CONTOURING
	bd.voxel_cell = STEAM_BASE_CELL
	bd.voxel_palette = SteamSkin.new().palette()
	d.base_def = bd
	d.base_top = 0.0
	d.constrain_to_base = true
	d.overhang = 0.10
	d.inner_radius = 2.2
	d.ring_step = 0.6
	d.backdrop_angle = 90.0
	d.backdrop_arc = 90.0
	d.ground_step = 1.0
	d.shrink = 0.84
	## 12 轮：矩形台面有剔除兜底，relax 推多了顶多是被剔掉一件（日志里看得见），
	## 不会像六边形那样推出悬空。所以这里可以少推几轮、多留一点构图密度。
	d.relax_iterations = 12
	d.voxel_grid_snap = STEAM_CELL
	d.accent_lights = _steam_lights()
	return d


## 氛围灯：锅炉炉火（暖橙、闪）/ 两盏码头灯笼 / 飞艇舷窗 / 锅炉上方的冷白蒸汽。
##
## 五盏灯的 offset 都照抄下面配方表的落位。蒸汽朋克的"活着"全靠这几盏：
## 炉火是暖的、蒸汽是冷的，一暖一冷两团光把"工坊正在运转"讲出来。
static func _steam_lights() -> Array:
	return [
		{&"color": Color(1.00, 0.60, 0.26), &"energy": 2.0, &"radius": 2.8,
			&"offset": Vector3(5.45, 0.0, 1.98), &"height": 0.55, &"flicker": 0.25},
		{&"color": Color(0.80, 0.88, 1.00), &"energy": 0.7, &"radius": 2.2,
			&"offset": Vector3(5.45, 0.0, 1.98), &"height": 2.10, &"flicker": 0.0},
		{&"color": Color(1.00, 0.85, 0.55), &"energy": 1.3, &"radius": 2.2,
			&"offset": Vector3(-2.50, 0.0, 4.33), &"height": 0.42, &"flicker": 0.20},
		{&"color": Color(1.00, 0.85, 0.55), &"energy": 1.3, &"radius": 2.2,
			&"offset": Vector3(2.50, 0.0, 4.33), &"height": 0.42, &"flicker": 0.20},
		{&"color": Color(1.00, 0.88, 0.62), &"energy": 1.2, &"radius": 2.4,
			&"offset": Vector3(-0.75, 0.0, -2.07), &"height": 1.80, &"flicker": 0.0},
	]


## 蒸汽朋克画风。**不走框架内置 6 套**，与用例二同理，理由有二：
##
## ① 金属观感必须开 [member ToonStyleDef.spec_step]：黄铜 / 铁 / 玻璃的区分
##    一半来自"有没有那一点块状高光"，而框架预设里只有 storybook 与 candy 开了它。
## ② 雾密度要自己给。蒸汽朋克要"有雾气"，但雾是按**距相机**算的，
##    而本场景的长焦把相机推到 60 米外 —— 0.016 在那里是 62% 洗白。
##    0.004 约 21%，刚好是"空气里有水汽"而不是"整张画糊掉"。
##
## 光位压到侧上（[member key_light_dir] 的 y 只有 0.70）：
## 金属的高光与阴影交界要**斜着切过形体**才像金属，正面平光会让黄铜变塑料。
static func _steam_style() -> ToonStyleDef:
	var s := ToonStyleDef.new()
	s.title = "蒸汽朋克黄铜"
	s.resource_name = s.title
	s.roughen = 0.30
	s.voxel_size = STEAM_CELL
	## 金属感靠 `metallic` 不靠压 roughness：铜铁件本身不脏，只是要有一道环境反射边。
	## 这里**不能**给全局 metallic > 0 —— 分件材质由 [method ToonPaletteDef.by_hint]
	## 逐索引取色，但粗糙度/金属度是 [ToonStyleDef] 上的**全局**字段，一给就木头也变金属。
	## 保持 0 + 给足 specular，让每个 swatch 各自靠固有色区分。
	s.roughness = 0.55
	s.metallic = 0.0
	s.specular = 0.55
	s.key_light_color = Color(1.0, 0.94, 0.84)
	## 光位压到侧上（y 0.55）：金属的高光交界要斜着切过形体才像金属。
	## 更要紧的是 —— 高光判据是 N·H，光从正上方打、所有朝上的面 N·H≈1，
	## 实测整块甲板顶与气囊顶一起白掉。光位压低后顶面才退出镜面角。
	s.key_light_dir = Vector3(-0.62, 0.55, -0.55)
	s.outline_mode = ToonStyleDef.OutlineMode.INVERTED_HULL
	s.outline_width = 0.006
	s.outline_color = Color(0.16, 0.13, 0.14, 1.0)
	s.ambient = Color(0.70, 0.72, 0.80)
	## 0.50：环境光是这里唯一的暗部托底（自写 shader 的 EMISSION 补偿已删除），
	## 给低了飞艇吊舱背光面就是一块死黑 —— 实测飞艇整个黑掉。
	s.ambient_energy = 0.50
	s.fog_color = Color(0.60, 0.62, 0.70)
	s.fog_density = 0.004
	return s


static func _steam(tag: String, gen_file: String, count: int, role: int,
		opt: Dictionary) -> DioramaRecipe:
	return _recipe_in(GEN_DIR_STEAM, SteamSkin.new(), STEAM_CELL,
		tag, gen_file, count, role, opt)


static func _steam_recipes() -> Array:
	return [
		## —— 主体：小型蒸汽飞艇 ——
		## 停在 -X 偏 -Z 的角落（angle 250、radius 2.2），而不是画面正中：
		## 飞艇全长 4.5 米，避让外接半径 2.6 —— 它站中间的话，
		## 锅炉与两组道具都得离它 3 米以上，台面上就再也排不下别的了。
		_steam("airship", "AirshipGen.gd", 1, DioramaRecipe.Role.SUBJECT, {
			"layout": DioramaRecipe.Layout.RING,
			"radius": 2.2, "angle": 250.0, "radius_jitter": 0.0, "angle_jitter": 0.0,
			## TANGENT：飞艇轴向沿切线 ⇒ 侧对着镜头，全长都能看见。
			## 朝圆心摆的话它是一根对着镜头的棒子，气囊再好看也只剩一个截面。
			"facing": DioramaRecipe.Facing.TANGENT,
			## 抬到半空 0.75 米 —— "停靠在码头旁"，不是落地的。
			## 摆放层的 lift 会把最低点压回地面，这个偏移是在 lift **之后**加的。
			"y_offset": 0.75,
			"kind_id": 1,
		}),

		## —— 环境：木质码头 + 锅炉 ——
		_steam("dock", "DockPlankGen.gd", 1, DioramaRecipe.Role.ENV, {
			"layout": DioramaRecipe.Layout.RING,
			"radius": 3.2, "angle": 90.0, "radius_jitter": 0.0, "angle_jitter": 0.0,
			"facing": DioramaRecipe.Facing.TANGENT,
			"kind_id": 2,
		}),
		_steam("boiler", "BoilerGen.gd", 1, DioramaRecipe.Role.ENV, {
			"layout": DioramaRecipe.Layout.RING,
			"radius": 5.8, "angle": 20.0, "radius_jitter": 0.05, "angle_jitter": 3.0,
			"facing": DioramaRecipe.Facing.CENTER,
			"kind_id": 3,
		}),

		## —— 道具：两组码头杂物，分站 +Z 两侧 ——
		## 同脚本用两次：几何一致，但 [member DockPropsGen._flip] 会让机械臂
		## 一个朝左一个朝右，落位角度也差 60°，读起来是两台不同的机器。
		_steam("props_a", "DockPropsGen.gd", 1, DioramaRecipe.Role.PROP, {
			"layout": DioramaRecipe.Layout.RING,
			"radius": 5.0, "angle": 120.0, "radius_jitter": 0.0, "angle_jitter": 0.0,
			"facing": DioramaRecipe.Facing.CENTER,
			"kind_id": 4,
		}),
		_steam("props_b", "DockPropsGen.gd", 1, DioramaRecipe.Role.PROP, {
			"layout": DioramaRecipe.Layout.RING,
			"radius": 5.0, "angle": 60.0, "radius_jitter": 0.0, "angle_jitter": 0.0,
			"facing": DioramaRecipe.Facing.CENTER,
			"kind_id": 5,
		}),
	]

