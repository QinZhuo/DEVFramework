@tool
class_name DioramaRecipe extends Resource
## 微缩小场景配方 —— 比 [PropRecipe] 多三样东西：**角色**、**落位方式**、**环带**
##
## ============================ 为什么不能直接复用 PropRecipe ============================
## [PropRecipe] 服务的是 [WorldAssembler] 的**街道式线性布局**：
## 沿 +X 首尾相铺一条主街，其余按"街道两侧 / 路肩 / 独立地块"挂在锚点上。
## 那套落位隐含两个前提 —— **地面是大范围起伏地形**、**镜头是街道视角**。
##
## 微缩小场景两个前提都不成立：地面是一块几十厘米的**展示底座**（基本是平的），
## 镜头是俯视整块底座。于是需要三种街道布局里根本没有的落位：
## · [constant Layout.CENTER] 主体居中（井、飞艇、无人机在架上）
## · [constant Layout.RING] 道具环绕成圈（路灯、长椅、顾客围一圈）
## · [constant Layout.BACKDROP] 背板沿弧线围合（墙面、管道、通风口）
##
## 硬套街道布局的结果很具体：所有道具会被摊成一条直线，围不出"一个角落"的叙事。
##
## ============================ 与 PropRecipe 一致的部分 ============================
## 仍然只声明"要什么、各几个、烘焙精度多少"，**不含任何几何描述** ——
## 形状永远在各自的 [PropGen] 子类里。本类同样不认识"面包店"或"路灯"这种具体物体。
##
## [b]注意[/b] 本类在**框架**层且不含游戏语义：角色只有 SUBJECT / ENV / PROP 三档，
## 具体"面包店是主体、邮筒是道具"由项目层决定（见 `Scripts/Gen/DioramaPresets.gd`）。

## 在场景里扮演什么角色。只影响分组与统计，**不影响几何或落位**。
enum Role {
	SUBJECT,   ## 主体：视线第一落点，通常 1 个（CENTER 落位）
	ENV,       ## 环境：墙 / 管道 / 通风口 / 邻栋建筑等围合件（BACKDROP 落位）
	PROP,      ## 道具：可摆数量、体量小、丰富细节与叙事
}

## 怎么落位。这是与 [PropRecipe] 的核心区别。
enum Layout {
	CENTER,    ## 圆心（[member DioramaDef.inner_radius] 之外不算），主体用
	RING,      ## 环绕成圈：按 [member count] 均分整周，可加环带与抖动
	BACKDROP,  ## 沿 [member DioramaDef.backdrop_arc] 那段弧线围合，正面朝圆心
}

## 朝向。街道布局只有"面朝街道"一种选择，微缩场景需要更多。
enum Facing {
	CENTER,    ## 正面朝圆心（环带内圈默认 —— 所有东西都看着中心）
	OUTWARD,   ## 正面朝外（背板、外墙）
	TANGENT,   ## 沿环切线（路灯、长椅：顺着摆放一圈才自然）
	FIXED,     ## 固定用 [member angle]，不参与"朝中心"计算
}

@export var tag := "prop"              ## 分类标签，同时用于烘焙缓存键
@export var gen_script: Script         ## 生成器脚本（须 extends PropGen）
@export var count := 1                 ## 数量

@export var role: Role = Role.PROP
@export var layout: Layout = Layout.RING

## 环带序号：0 = 内圈，每加 1 外扩 [DioramaDef.ring_step] 米。
## 同环带的配方会互相挤，靠 [method PropLayoutTool.relax] 推开。
@export var band := 0

## 期望方位角（度）。[b]不小于 0[/b] 时作为基准角，[b]小于 0[/b] 时：
## · RING → 按 count 均分整周（0°, 360/n, …）
## · BACKDROP → 在弧线上均分
## · CENTER → 取 0°
@export var angle := -1.0

## 角度抖动（度）。真实 diorama 没有正圆排列，全是 0 度会很假。
@export_range(0.0, 90.0, 0.5) var angle_jitter := 8.0

## 绝对半径（米）。[b]小于 0[/b] 时由 [DioramaDef.inner_radius] + band 推导。
@export_range(-1.0, 20.0, 0.05) var radius := -1.0
@export_range(0.0, 2.0, 0.01) var radius_jitter := 0.12

@export var facing: Facing = Facing.CENTER

## 贴地方式：-1 = 按 [method PropGen.meta] 的 surface_snap 决定，
## ≥0 = 覆盖为对应的 [enum PropLayoutTool.Snap]。
## 挂壁件（招牌、管道）要 [constant PropLayoutTool.Snap.MAX]，
## 悬空件（电缆、雾气支架）配 [member y_offset] 抬起来。
@export var snap := -1
@export var y_offset := 0.0

## —— 烘焙精度（与 PropRecipe 同义）——
@export_range(0.02, 0.5, 0.01) var voxel_size := 0.12
@export var sharp_normal := true       ## 主平面特征法线（三渲二硬边的关键）
@export_range(0.0, 0.2, 0.005) var sharpen := 0.0

## —— 双产物 ——
## 与 [PropRecipe] 同样的坑：必须**逐个配方**下发，只改包上的 Def 会静默失效。
@export_range(0, 256, 1) var voxel_res := 0        ## 体素最长边分辨率，0 = 不产体素
@export var voxel_palette: ToonPaletteDef = null    ## 体素调色板

## 目标体素边长（米）。>0 时**覆盖** [member voxel_res]，由生成器自报的局部尺寸换算。
##
## ============================ 为什么不能只填 voxel_res ============================
## [member voxel_res] 是"最长边切成几格"，所以**方块的物理边长 = 物体尺寸 / voxel_res**。
## 一个 8 米高的面包店和一个 0.5 米高的邮筒都填 `voxel_res = 32`，
## 得到的是 25 厘米和 1.6 厘米的方块 —— 拼在一起时"统一正方体"彻底不存在，
## 而这正是体素风格最核心的辨识特征。
##
## 填 0.1（本例）表示"我希望每个方块都是 10 厘米"，
## 由 [method DioramaBuilder] 换算成各物体自己的 voxel_res。
##
## ============================ 它是怎么变成方块边长的 ============================
## 换算基准是"最长边切几格"，而体素网格的定位盒是**窄带盒**（比模型宽约 2×band），
## 两者不同源。所以本字段在 [method make_gen_def] 里被**直接**写进
## [member PropGenDef.voxel_cell]（由提取器按物理边长切格），
## [method DioramaBuilder._resolve_gen_def] 算出的 voxel_res 只作为日志/读数参考。
## 早先只靠 res 反推时，实测 7.9 米的面包店方块偏大 9%、1.16 米的长椅偏大 66% ——
## 同一场景里方块能差一倍以上，而中间数字全都"正常"。
@export_range(0.0, 1.0, 0.005) var voxel_cell := 0.0

## 稳定编号：用于 [method PropGenTool.mix_seed] 派生单体 seed。
## 同一类配方调整摆放顺序**不该**改变已有单体的形状。
@export var kind_id := 0

## 造烘焙 Def。与 [method PropRecipe.make_gen_def] 同构。
func make_gen_def() -> PropGenDef:
	var d := PropGenDef.new()
	d.voxel_size = voxel_size
	d.margin = 0.4
	d.algo = MeshExtractor.Algo.DUAL_CONTOURING
	d.sharp_normal = sharp_normal
	d.sharpen = sharpen
	d.voxel_res = voxel_res
	d.voxel_palette = voxel_palette
	## 目标边长直接下发，不让下游再从 res 反推 —— 见 [member voxel_cell] 的说明。
	d.voxel_cell = voxel_cell
	return d

func get_desc(_data) -> String:
	return "DioramaRecipe[%s ×%d · %s]" % [tag, count, _layout_name()]


func _layout_name() -> String:
	match layout:
		Layout.CENTER: return "中心"
		Layout.BACKDROP: return "背板"
		_: return "环带%d" % band
