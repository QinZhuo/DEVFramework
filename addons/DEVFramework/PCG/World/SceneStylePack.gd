@tool
class_name SceneStylePack
extends Resource
## 场景风格包 —— **一个配置切换整个场景的画风与内容组合**
##
## ============================ 为什么需要这一层 ============================
## 在此之前，画风、配色、内容三件事是**散的**：
## · [ToonStyleDef] 管质感（多硬、多光滑、描边多粗）
## · [ToonPaletteDef] 管配色
## · 配方（项目层 [code]PropRecipe[/code]）管"要哪些单体、各摆几个、摆哪"
##
## 三者各存各的，于是"换成和风场景"要手动改三处，且改完极易出现
## **风格与内容错配** —— 例如 `wa_shoji`（和风障子）那套薄壳画风配上一堆街边店铺，
## 抽壳把店面抽成纸片，谁都不像。画风预设与内容预设必须**成套**给。
##
## 这正是成熟 PCG 工具的做法：Houdini 的 HDA、Infinigen 的 scene 配置，
## 都是"一个资产描述一整类场景"，而不是把参数撒在各处让用户自己凑。
##
## 本类就是那个"成套"的落点：
## **风格包 = 画风 + 配色 + 内容组合 + 布局参数 + 输出形态 + 镜头与舞台**。
##
## ============================ 为什么镜头也算"画风" ============================
## 早期版本把镜头留在场景里，于是"切风格包"只换了模型不换画幅：
## 微缩场景配 60° 广角、日式街景配长焦，观感永远对不上。
## 而微缩感三要素（长焦 / 浅景深 / 边缘收暗）里，前两者**根本不在材质上** ——
## 材质再干净，广角 + 全清晰 + 亮边缘 = "游戏截图"，不是"模型照片"。
## 所以镜头与后期必须与画风成套给，由 [MiniatureStage] 负责把它们落到场景里。
##
## ============================ 分层边界 ============================
## 本类在**框架**层，因此：
## · 只认识框架类型（[ToonStyleDef] / [ToonPaletteDef] / [PropGenDef]）；
## · [member recipes] 是**未类型化** [Array]，元素按鸭子类型使用 ——
##   框架不认得"配方"这个项目类型，组装器由项目侧的
##   `WorldAssembler.from_pack()` 建立；
## · **不含任何内置预设**。"日式街道 / 和风神社 / 微缩童话"这类具体内容
##   属于项目语义，在 `Scripts/Gen/SceneStylePresets.gd`。
##
## == 典型用法 ==
## [codeblock]
## var pack = SceneStylePresets.presets()[&"wa_shrine"]
## var asm = WorldAssembler.from_pack(pack, ground_y)   # 项目层建立
## pack.apply_material(mi)                # 单体按本包的画风上材质
## pack.apply_stage(self, camera)         # 长焦 / 景深 / 雾 / 暗角，一次到位
## camera.position += dir * 40 * MiniatureStage.frame_scale(pack.camera_fov)
## [/codeblock]

## 输出形态 —— 同一份烘焙数据可以落成两种模型
enum Output {
	MESH,    ## 低多边形网格：三渲二主形态，面少、色阶干净
	VOXEL,   ## 体素网格：方块风，贪心合并后面色同样干净
	BOTH,    ## 两种都出，用于对照"同一次烘焙的两种解读"
}

@export var title := ""
@export var desc := ""

## —— 画风 ——
@export var style: ToonStyleDef
@export var palette: ToonPaletteDef

## —— 烘焙 ——
## 一个 Def 同时决定网格精度与体素分辨率：两者共用同一次场烘焙，
## 所以"要体素"只是多提一次，不必为它单独配一套精度。
@export var gen_def: PropGenDef

## —— 内容 ——
## 元素为项目层的配方资源。这里刻意用**未类型化** [Array]：
## `@export var recipes: Array[PropRecipe]` 在编辑器里能正确显示，
## 但运行时对 Resource 属性赋值 typed array 会被拒（"value of type 'Array'"），
## 而风格包恰恰要**运行时**构造（见项目层 `SceneStylePresets.presets`），不是只在编辑器里拖。
@export var recipes: Array = []

## —— 布局 ——
@export var street_step := 4.0
@export var output: Output = Output.MESH
@export var greedy := true          ## 体素是否走贪心合并（见 ModelBaker.build_voxel_node）

## 保持画面大小不变时相机该退到的距离（由 [method apply_stage] 算写）。
## 演示场景直接拿它当相机距离；不想耦合的场景可以不读。
var stage_distance_hint := 0.0


## —— 镜头 ——
## 微缩感的第一要素是**长焦**：视场角越小 ⇒ 透视越压缩 ⇒ 前后物体看起来贴在同一块底板上。
## 代价是画面会跟着"凑近"，所以换 FOV 必须同步后退（见 [method MiniatureStage.frame_scale]）。
@export_range(8.0, 90.0, 0.5) var camera_fov := 28.0

## 景深强度：0 = 全画面清晰（那就没有"摆件感"了，只剩雾）。
## 0.5~0.75 是"焦点之外明显糊、焦点处仍锐"的范围。
@export_range(0.0, 1.0, 0.01) var dof_amount := 0.55

## 远景虚化起点（米）：超过这个距离开始糊。
## 数值必须**跟着场景尺度**改：街景 55 米合理，桌面尺度就该改成 3 米。
@export_range(0.0, 500.0, 0.5) var dof_far_distance := 55.0

## 远景虚化过渡长度（米）：太短会看见一条清晰的"糊/不糊"界线，比不虚化更假
@export_range(0.0, 200.0, 0.5) var dof_far_transition := 22.0

## 近景虚化距离（米）：0 = 不虚化贴近镜头的东西（默认关：糊掉前景会毁掉摆件的"能上手看"感）
@export_range(0.0, 100.0, 0.5) var dof_near_distance := 0.0
@export_range(0.0, 100.0, 0.5) var dof_near_transition := 4.0


## —— 背景 ——
## 微缩摆件通常不是"站在某片风景下"，而是"放在桌面上对着柔光"。三种取法：
enum Backdrop {
	KEEP,    ## 不动场景里已有的背景设置（用户自己配好的 WorldEnvironment）
	FLAT,    ## 纯色背景 + 暗角：最像"拍在纯色台布上"
	SKY,     ## 程序天空（黄昏 / 晴天这类需要天地过渡的场景）
}

@export var backdrop: Backdrop = Backdrop.FLAT

## FLAT 的底色，同时作为 SKY 的地面色
@export var backdrop_color := Color(0.80, 0.84, 0.90)

@export var sky_top_color := Color(0.38, 0.57, 0.84, 1)
@export var sky_horizon_color := Color(0.86, 0.91, 0.96, 1)


## —— 环境 ——
## 雾色与雾密度的**真值在 [member style] 上**（`style.fog_color` / `style.fog_density`），
## 这里不重复一份，只给倍率：`Environment` 的雾与材质的雾是两套（前者染整幅画面，
## 后者只染三渲二材质），微缩场景通常要环境雾更重一点把整张图压进小盒子。
@export var env_fog_enabled := true
@export_range(0.0, 4.0, 0.01) var env_fog_gain := 1.0

## 雾是否染天空。微缩摆件默认**不染**：背景一被雾压灰，整张图立刻"廉价"
@export var env_fog_sky_affect := false

## 后期调色。饱和度略升（>1）能把三渲二的大平色从"塑料"拉回"插画"
@export var env_adjust_enabled := true
@export_range(-1.0, 1.0, 0.01) var env_brightness := 0.0
@export_range(0.0, 2.0, 0.01) var env_contrast := 1.0
@export_range(0.0, 2.0, 0.01) var env_saturation := 1.02

## 曝光倍数。**只能落在 `Environment.tonemap_exposure`** ——
## `CameraAttributesPractical` 里没有这个属性（实测 ClassDB），别往那儿写。
@export_range(0.0, 4.0, 0.01) var exposure := 1.0

## 显式关掉 SSAO / glow。**这是画风决策，不是画质档位**：
## SSAO 会在色阶交界糊出一圈脏灰（把两档色变成三档脏色），
## glow 会让描边与高光溢出轮廓（把硬边描边糊成一团）。两者都不报错，只是"看着不对"。
@export var disable_ssao := true
@export var disable_glow := true


## —— 暗角（微缩感第三要素）——
## `Environment` 里**没有暗角项**，只能自己在屏幕空间画（见 [MiniatureStage.apply_vignette]）。
@export var vignette_enabled := true
@export_range(0.0, 2.0, 0.01) var vignette_strength := 0.42

## 越大越柔。小模型要柔：锐利的暗角看着像后期滤镜而不像镜头
@export_range(0.05, 2.0, 0.01) var vignette_softness := 0.62

## 暗角色。惯例是**偏冷紫**（与暖白主光成对），别用纯黑 —— 纯黑暗角看着像"屏幕没擦干净"
@export var vignette_tint := Color(0.06, 0.05, 0.10, 1.0)

## 中心向暖色偏一点。这是让小模型"看起来精致"的老手法（冷暖分离）
@export_range(0.0, 1.0, 0.01) var vignette_warmth := 0.18

## 极弱胶片颗粒：压掉大面积平色带来的塑料感。> 0.05 会明显脏
@export_range(0.0, 0.2, 0.001) var vignette_grain := 0.012


# ================================================================== 取用

## 把本包的双产物设置**落到每个配方上**。
##
## 组装器烘焙时用的是配方自己的烘焙参数，不是本包的 [member gen_def]，
## 所以"这套场景要出体素"必须逐个配方下发 —— 否则设置静默失效，
## 症状是选了体素形态却一个体素都渲染不出来，且没有任何报错。
## 同理 voxel_palette 也要下发，体素才会用本包的配色分件。
func apply_output_to_recipes() -> void:
	if gen_def == null:
		return
	for r in recipes:
		if r == null:
			continue
		r.voxel_res = gen_def.voxel_res
		r.voxel_palette = gen_def.voxel_palette

## 把一个单体按本包的画风上材质（含描边）。
## 注意：这里**不**读配方里的 sharp_normal / sharpen —— 那是几何精度的事，
## 画风统一由本包的 [member style] 决定，否则同一场景里会出现两种描边粗细。
func apply_material(mi: MeshInstance3D, use_vertex_color := false) -> Node3D:
	if mi == null or style == null or palette == null:
		return null
	return ToonMaterial.apply(mi, style, palette, mi.get_parent(), use_vertex_color)

## 本包是否要体素产物
func wants_voxel() -> bool:
	return output != Output.MESH


## 把本包的镜头 / 环境 / 暗角**一次装到场景里**，返回新建或复用的暗角 [CanvasLayer]。
##
## [param host] 是场景根（或任意父节点）——暗角层挂在它下面，
## [Environment] 找不到就地新建（见 [method MiniatureStage.ensure_environment]），
## 于是调用方不必先操心"场景里有没有环境节点"。
##
## [param base_distance] 传了就把"保持画面大小不变所需的相机距离"一并算好并
## 写进 [member stage_distance_hint]——长焦会让画面猛地凑近，不后退就会看到
## "切风格包时突然变焦"。不想让本类碰相机距离时不传即可。
##
## 幂等：反复调用只更新数值，不会叠出多层暗角或多个 `WorldEnvironment`。
func apply_stage(host: Node, cam: Camera3D, base_distance := 0.0) -> CanvasLayer:
	if host == null:
		return null
	if base_distance > 0.0:
		stage_distance_hint = base_distance * MiniatureStage.frame_scale(camera_fov)
	return MiniatureStage.apply(host, cam, self)


## 给作者/调试用的一行摘要（`标题 · 2档 · 描边0.012 · 长焦28° · 暗角0.42`）
##
## 注意用 [member Resource.resource_name] 而不是 `name` —— 本类直接继承 [Resource]，
## 没有 [Def] 基类那个翻译用的 `name` 属性（写了会解析失败，不是运行期才发现）。
func get_desc(_data) -> String:
	var parts := "%s · %d档 · %s · 长焦%.0f°" % [
		title if not title.is_empty() else resource_name,
		style.bands if style != null else 0,
		"无描边" if style == null or style.outline_mode == ToonStyleDef.OutlineMode.OFF
			else "描边%.3f" % style.outline_width,
		camera_fov,
	]
	if vignette_enabled:
		parts += " · 暗角%.2f" % vignette_strength
	return parts
