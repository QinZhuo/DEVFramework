@tool
class_name VoxelSkin
extends RefCounted
## 用例四「体素面包店街角」的固定 17 色暖色板 —— 部位索引与色值的**唯一约定**
##
## ## 为什么要一份共享表
## 体素分色靠 [method PropGen.voxel_regions] 里写死的整数索引。9 个生成器各写各的魔数，
## 改一次色板要翻 9 个文件，且"这个 3 是什么意思"只有作者知道 —— 部位色错位时
## 画面上表现为"某个部件颜色怪"，排查成本极高。索引与色值必须同处一表。
##
## ## 索引分配纪律
## · **0 号留给主体色**，且每个生成器的 [method voxel_regions] 都以一个
##   覆盖 [method PropGen.local_bounds] 的「兜底区」收尾，索引指向自己的主色。
## · 兜底区**不可省**。少了它，未命中部位会落到 [method VoxelExtractor.extract] 的
##   「按归一化高度分层」，而本表是 17 个**任意色相**的 swatch，不是色阶 ——
##   高度分层会把同一个零件的上下沿刷成绿、黄、砖红，完全失控。
##   用固定 swatch 时按高度上色是有害的，不是无害的默认行为。
## · 部位色只占 1~15。新增部位请从这里取号，不要就地写数字。

#region 部位索引

const CREAM := 0     ## 奶油色：底层外墙（主体色）
const WOOD := 1      ## 深棕木：门框、窗棂、屋檐木梁
const WINDOW := 2    ## 暖黄发光：窗玻璃
const ROOF := 3      ## 陶红：屋瓦
const STONE := 4     ## 冷灰石：底座、人行道
const LEAF := 5      ## 苔绿：树叶
const BARK := 6      ## 树皮棕
const METAL := 7     ## 深灰金属：路灯、邮筒、栏杆
const WHITE := 8     ## 奶白：台面、器皿、蒸汽
const AWNING := 9    ## 砖红：遮阳棚、邮筒箱体
const BREAD := 10    ## 麦金：面包
const SKIN := 11     ## 肤色：顾客脸与手
const CLOTH1 := 12   ## 靛蓝：顾客衣
const CLOTH2 := 13   ## 芥黄：顾客衣
const SAND := 14     ## 浅棕：二三层外墙
const LAMP := 15     ## 亮黄：灯具发光面
## 树冠提亮绿。单独占一格而不是复用 [constant WHITE]：
## [constant WHITE] 是 0.976/0.965/0.937 的近白奶色，扣在苔绿树冠顶上
## 亮度过冲且**色相翻到中性**，读出来是一顶雪帽，不是"受光面"；
## 高光该沿本体色相提亮，所以是绿的浅绿。
const LEAF_HI := 16  ## 浅苔绿：树冠顶层受光面

#endregion

## 17 色暖色板。顺序**必须**与上面的索引常量一一对应 —— 提取器按索引取色，错位即错色。
##
## 取色纪律（对齐 [ToonPaletteDef] 的日系三铁律）：高明度、低饱和、暗部染色不压黑。
## 所以这里的"深棕"是偏紫的深棕（0.28, 0.18, 0.15）而不是纯褐，
## "阴影"往冷紫走，这样体素硬边 + 描边叠起来才不像塑料。
const SWATCHES: Array[Color] = [
	Color(0.949, 0.878, 0.792),  ## 0  CREAM  奶油
	Color(0.280, 0.180, 0.150),  ## 1  WOOD   深棕木
	Color(1.000, 0.847, 0.541),  ## 2  WINDOW 暖黄发光
	Color(0.788, 0.353, 0.278),  ## 3  ROOF   陶红
	Color(0.639, 0.643, 0.686),  ## 4  STONE  冷灰石
	Color(0.478, 0.686, 0.396),  ## 5  LEAF   苔绿
	Color(0.427, 0.298, 0.220),  ## 6  BARK   树皮棕
	Color(0.365, 0.373, 0.435),  ## 7  METAL  深灰金属
	Color(0.976, 0.965, 0.937),  ## 8  WHITE  奶白
	Color(0.878, 0.435, 0.325),  ## 9  AWNING 砖红
	Color(0.878, 0.706, 0.412),  ## 10 BREAD  麦金
	Color(0.976, 0.816, 0.690),  ## 11 SKIN   肤色
	Color(0.361, 0.435, 0.647),  ## 12 CLOTH1 靛蓝
	Color(0.902, 0.729, 0.361),  ## 13 CLOTH2 芥黄
	Color(0.812, 0.706, 0.588),  ## 14 SAND   浅棕
	Color(1.000, 0.925, 0.678),  ## 15 LAMP   亮黄灯光
	Color(0.639, 0.796, 0.510),  ## 16 LEAF_HI 浅苔绿（树冠顶层）
]

## 装配成框架侧要用的 [ToonPaletteDef]。
##
## 走 [member ToonPaletteDef.swatches] 而非让它插值出 16 级色阶：
## 插值只能在 base→shade→deep 三个锚点之间变化明度，做不出"奶白 + 陶红 + 暖黄光"
## 这种色相彼此无关的配色（详见 swatches 字段的说明）。
static func palette() -> ToonPaletteDef:
	var p := ToonPaletteDef.new()
	p.title = "体素面包店 · 暖色 17 色"
	p.resource_name = p.title
	p.swatches = SWATCHES.duplicate()
	## 描边与暗部仍然取 ramp 语义，保证描边不纯黑（ToonPaletteDef 文件头铁律③）
	p.base = SWATCHES[0]
	p.light = SWATCHES[8]
	p.shade = Color(0.62, 0.58, 0.70)
	p.deep = Color(0.42, 0.38, 0.55)
	p.outline = Color(0.22, 0.17, 0.26)
	return p

## 逐部位索引取色的材质提供者，供 [method DioramaBuilder.spawn] /
## [method PropBuild.to_mesh_instance] 使用。
##
## 传单个 [Material] 的话体素网格的每个 surface 都会挂上同一个主色，
## 本表的 17 个部位就全白画了 —— **且不报任何错**，画面上只是"整体一个颜色"。
static func material_provider(style: ToonStyleDef) -> Callable:
	return ToonMaterial.voxel_material_provider(style, palette())


## 兜底区：覆盖整个局部包围盒并钉死索引。
##
## [method PropGen.voxel_regions] 的返回值应当**以它收尾**（本表文件头说明了理由）。
static func all(bounds: AABB, index: int) -> Dictionary:
	return {&"aabb": bounds, &"index": index}

## 盒子 → 区域。以中心 + 尺寸书写，比 AABB 的 position/size 直观得多。
static func box(center: Vector3, size: Vector3, index: int) -> Dictionary:
	return {&"aabb": AABB(center - size * 0.5, size), &"index": index}

## 一条水平色带（限定 y 区间，XZ 覆盖全范围）—— 楼层分色、屋顶分色最常用。
static func band_y(y0: float, y1: float, half_xz: float, index: int) -> Dictionary:
	return box(Vector3(0.0, (y0 + y1) * 0.5, 0.0),
		Vector3(half_xz * 2.0, y1 - y0, half_xz * 2.0), index)
