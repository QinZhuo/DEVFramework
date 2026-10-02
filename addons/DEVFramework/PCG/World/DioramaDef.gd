@tool
class_name DioramaDef extends Resource
## 微缩小场景（diorama）定义 —— **展示底座 + 摆样几何 + 氛围**
##
## ============================ 它补的是哪一块 ============================
## 本模块原有两套场景级配置，**都不是**微缩小场景：
## · [SceneStylePack] 管"画面长什么样"：画风、配色、镜头、景深、暗角、后期
## · [WorldAssembler] 管"东西怎么摆"：但它是**街道式线性布局**，
##   沿 +X 首尾相铺一条主街、其余挂在街道锚点上，跨度动辄上百米
##
## 而微缩摆件的结构完全不同：**一块几十厘米的展示底座**，主体居中，
## 环境沿背板弧线围合，道具环绕成圈 —— 底座、簇式布局、氛围这三样
## 在原有两层里**一个都没有**。硬套的结果是所有道具被摊成一条直线，
## 围不出"一个角落"的小叙事。
##
## 本类把这三样补齐，并与 [SceneStylePack] 正交组合：
## [codeblock]
## var def  = DioramaPresets.presets()[&"voxel_bakery"]   # 搭法（项目层）
## var pack = SceneStylePresets.presets()[&"mini_fairy"]   # 画风（项目层）
## var b    = DioramaBuilder.build(def, world_seed)        # 框架
## pack.apply_material(mi); pack.apply_stage(self, camera) # 画风套上去
## [/codeblock]
##
## ============================ 分层红线 ============================
## 本类在**框架**层，因此只认识框架类型（[PropGenDef] / [ToonPaletteDef] / [DioramaRecipe]），
## 且**不含任何游戏语义** —— 没有"面包店""机库"这类具体内容，
## 那些在项目层 `Scripts/Gen/DioramaPresets.gd`。
## 底座本身是一个 [PropGen]（[member base_gen]）而不是写死的图元：
## "圆形金属切面""六边形岩石切面""齿轮浮雕边缘"这些差异交给生成器，
## 底座于是能复用同一套 SDF → 双产物管线，而不是另写一套网格代码。

# ============================================================== 底座

## 底座生成器脚本（须 extends PropGen）。留空 = 无底座（纯地面摆件）。
##
## 为什么底座也是 [PropGen] 而不是直接画个圆柱：
## 五个 diorama 用例里底座边缘要求各不相同 —— 圆形金属切面、六边形岩石切面、
## 矩形电路纹理切面、方块体素单元、黄铜齿轮浮雕。做成图元就得多写五个分支，
## 做成 [PropGen] 则每个底座就是一个普通生成器，能独立调 seed、能出体素。
@export var base_gen: Script = null

## 底座烘焙参数。留空 = 用默认（[member PropGenDef] 的 voxel_size 0.18）。
@export var base_def: PropGenDef = null

## 底座**上表面**的高度（米）—— 所有道具站的高度。
##
## 显式给而不是从底座网格反推：底座的 local_bounds.min.y 可能是 0，
## 也可能为了做底座侧裙往下扩到 -0.4，反推容易差一个偏移量。
@export var base_top := 0.0

## 道具是否被限制在底座范围内。关掉后道具可以探出边缘（做"探出悬崖的树"这类效果）。
@export var constrain_to_base := true

## 允许探出底座边缘的比例。0.15 = 道具外缘可超出底座半径 15%。
## 不给一点余量的话道具会被硬切在边界上，看着像被墙挡住。
@export_range(0.0, 1.0, 0.01) var overhang := 0.15

# ============================================================== 摆样几何

## 环带起始半径（米）：band 0 落在这一圈上。
## 应略大于底座上要留给主体的半径 —— 所有道具都从这一圈往外排。
@export_range(0.2, 20.0, 0.05) var inner_radius := 1.6

## 环带宽度（米）：每加一个 band 外扩这么多。
@export_range(0.1, 10.0, 0.05) var ring_step := 0.55

## 背板弧的中心方位角（度，0 = +X，90 = +Z）。
## 约定：**正对该角的镜头通常在 -Z 侧**，所以默认 90（背板在 +Z）。
@export var backdrop_angle := 90.0

## 背板弧张角（度）。180 = 半圈围合；接近 360 会把主体完全围死。
@export_range(30.0, 360.0, 1.0) var backdrop_arc := 200.0

## 地面采样步长（米）。展示底座基本是平的，给小值即可；
## 但底座若做成起伏地形（草地岛屿），这里要跟地形尺度匹配。
@export_range(0.2, 8.0, 0.1) var ground_step := 1.2

## 避让收缩系数：1.0 = 严格不重叠，0.9 = 允许挤压（更紧凑、更像摆满的展柜）
@export_range(0.3, 1.0, 0.01) var shrink := 0.92

## 全局避让迭代次数
@export_range(0, 64, 1) var relax_iterations := 24

## 体素格子对齐步长（米）。0 = 关。
##
## ============================ 为什么体素场景需要它 ============================
## 每个单体的体素格点都锚在**它自己的局部原点**上。所以哪怕全场用同一个
## voxel_size，两件相邻物体的体素也会各算各的 —— 叠加处出现半格错位，
## "unit cube construction" 的统一方块感就没了。
##
## 把落位 XZ 吸附到 voxel_size 的整数倍，全场就落在同一套格点上了。
## 体素风格场景（[enum PropBuild.Form.VOXEL_ITEM]）建议开；网格风格场景必须关 ——
## 吸附会把本来该随意的摆放变成机械的格子阵。
@export_range(0.0, 1.0, 0.01) var voxel_grid_snap := 0.0

# ============================================================== 氛围

## 附加点光（自发光的外溢）：霓虹、警示灯、灯笼、篝火、窗户暖光。
##
## 为什么氛围要在这里而不是只靠 [SceneStylePack]：
## 画风包管的是"整幅画面"（雾、暗角、曝光），而 diorama 的氛围是**局部的** ——
## 一盏悬在半空的警示灯、一个窗里的暖黄，跟全局雾暗角是两回事。
##
## 每项为未类型化字典（与 [member SceneStylePack.recipes] 同理，框架不类型注解项目类）：
## [codeblock]
## {&"color": Color, &"energy": 1.5, &"radius": 1.2,
##  &"offset": Vector3, &"height": 2.0,     # offset 为底座中心的水平偏移
##  &"flicker": 0.0}                          # >0 时按噪声抖动强度（火焰/警示灯）
## [/codeblock]
@export var accent_lights: Array = []

# ============================================================== 取用

## 某一环带的半径（米）。
func radius_for_band(band: int) -> float:
	return inner_radius + float(band) * ring_step

## 底座半径（米）。用于 [member constrain_to_base] 的越界判定；
## 无底座时返回 0（调用方应据此跳过判定）。
##
## ============================ 为什么现算而不是存一个字段 ============================
## 底座是 [member base_gen] 这个生成器，不是写死的图元（见该字段的说明）。
## 存一个 `base_radius` 字段，就必须让人在**两处**各填一次半径：
## 一次在生成器的 [method PropGen.local_bounds]，一次在这里 ——
## 而两处不一致时**不报错**，只是道具被悄悄剔掉几个（越界剔除是 `continue`，
## 不是警告），画面上表现为"道具少了几个"，几乎无法归因。
## 现在直接向生成器要包围盒算外接圆半径，只有一个真值来源。
##
## 代价：这里会 `new()` 一个生成器实例问一句 [method PropGen.local_bounds]。
## [PropGen] 继承 [RefCounted]，实例用完即回收，没有泄漏问题。
## 注意 [method PropGen.local_bounds] 应当是**纯声明**：若某个生成器把
## `prepare()` 里的随机化结果写进包围盒，这里量到的会与实际烘焙出的略有出入
## （半径偏大 ⇒ 剔得偏保守；偏小 ⇒ 可能漏掉越界物）。这是可接受的保守方向。
func base_radius() -> float:
	if base_gen == null:
		return 0.0
	var gen := base_gen.new() as PropGen
	if gen == null:
		return 0.0
	var bb := gen.local_bounds()
	## 取 XZ 四个角到原点的最大距离，而不是 `size.xz.length() / 2`：
	## 后者假设包围盒以原点为中心，而底座完全可能偏心（例如裙边只往一侧扩）。
	var r := 0.0
	for i in 4:
		var x := bb.end.x if (i & 1) != 0 else bb.position.x
		var z := bb.end.z if (i & 2) != 0 else bb.position.z
		r = maxf(r, Vector2(x, z).length())
	return r


## 底座在水平面上的半尺寸（XZ，单位米；`.x` 对世界 X，`.y` 对世界 Z）。
## 无底座时返回 [constant Vector2.ZERO]。
##
## [method base_radius] 是给"显示 / 日志"用的**外接圆**半径；
## 真正判越界要用这个逐轴半尺寸。区别在方底座上一眼可见：
## 10×10 的方底座外接圆半径 7.07 米（对角线），但沿轴向只到 5 米。
## 用圆去卡，四条边中段会**放过**一批悬空道具 —— 而越界剔除是静默的 `continue`，
## 画面上只表现为"某个道具不见了"。
func base_half_extent() -> Vector2:
	if base_gen == null:
		return Vector2.ZERO
	var gen := base_gen.new() as PropGen
	if gen == null:
		return Vector2.ZERO
	var bb := gen.local_bounds()
	## 不假设包围盒以原点为中心：取"离原点最远的那一侧"作为半尺寸。
	return Vector2(maxf(absf(bb.position.x), absf(bb.end.x)),
		maxf(absf(bb.position.z), absf(bb.end.z)))

func get_desc(_data) -> String:
	var n := accent_lights.size()
	return "Diorama[环带 %.2f+%.2f · 弧 %.0f° · 氛围灯 %d]" % [
		inner_radius, ring_step, backdrop_arc, n]
