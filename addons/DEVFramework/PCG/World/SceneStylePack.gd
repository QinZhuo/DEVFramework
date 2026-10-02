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
## 本类就是那个"成套"的落点：**风格包 = 画风 + 配色 + 内容组合 + 布局参数 + 输出形态**。
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
