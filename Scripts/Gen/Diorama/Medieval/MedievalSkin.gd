@tool
class_name MedievalSkin
extends DioramaSkin
## 用例二「低多边形中世纪村庄广场」的固定 20 色 JRPG 色板
##
## ## 索引分配纪律（与 [VoxelSkin] 同律）
## · 0 号是主体色且用作兜底：这里是 [constant GRASS]，因为整座村庄站在一块草地上，
##   草地是面积最大的面，一件反面예 没写到的零件落到它上面也说得通。
## · 每个生成器的 [method PropGen.voxel_regions] 都必须以覆盖
##   [method PropGen.local_bounds] 的兜底区收尾，否则未命中体素会落到
##   VoxelExtractor 的「按归一化高度分层」—— 那会把一座木屋刷成彩虹。
##
## ## 取色纪律
## JRPG 低模的通行做法：**色相少、明度跨度大、饱和度中低**。
## 所以这里没有纯的草木绿（用 0.62/0.78/0.42 的苔绿），屋顶只留陶红与靛蓝两种，
## 水的蓝刻意向绿靠（0.36/0.62/0.72），让整幅画统一在"暖土 + 冷石"的对子里。

#region 部位索引

const GRASS := 0      ## 草地绿：底座顶面（主体色）
const ROCK := 1       ## 岩灰：岛屿切面岩石
const DIRT := 2       ## 土径棕：广场地面、溪岸
const STONE := 3      ## 石墙灰：塔身、井圈
const STONE_DK := 4   ## 深石灰：石墙暗层、台阶侧面
const WOOD := 5       ## 深木棕：梁柱、门板
const WOOD_LT := 6    ## 浅木黄：木屋墙板、桥面
const THATCH := 7     ## 茅草黄褐：屋顶草
const ROOF_RED := 8   ## 陶红瓦：木屋坡顶
const ROOF_BLUE := 9  ## 靛蓝瓦：塔顶锥、次要屋顶
const WATER := 10     ## 水蓝：小溪
const LEAF := 11      ## 树叶深绿
const TRUNK := 12     ## 树干棕
const FIRE := 13      ## 篝火橙：柴堆
const EMBER := 14     ## 亮橙：火苗顶端
const SKIN := 15      ## 肤色：村民头与手
const CLOTH_A := 16   ## 赭红：村民衣（暖）
const CLOTH_B := 17   ## 靛蓝：村民衣（冷）
const METAL := 18     ## 深灰铁：井架五金、桶箍
const CREAM := 19     ## 奶白：旗帜、井绳、容器

#endregion

## 20 色。顺序**必须**与上面的索引常量一一对应。
const SWATCHES: Array[Color] = [
	Color(0.478, 0.706, 0.396),  ## 0  GRASS     草地绿
	Color(0.549, 0.549, 0.588),  ## 1  ROCK      岩灰
	Color(0.639, 0.522, 0.376),  ## 2  DIRT      土径棕
	Color(0.729, 0.741, 0.741),  ## 3  STONE     石墙灰
	Color(0.451, 0.475, 0.510),  ## 4  STONE_DK  深石灰
	Color(0.353, 0.243, 0.176),  ## 5  WOOD      深木棕
	Color(0.788, 0.635, 0.408),  ## 6  WOOD_LT   浅木黄
	Color(0.780, 0.663, 0.376),  ## 7  THATCH    茅草黄褐
	Color(0.745, 0.318, 0.271),  ## 8  ROOF_RED  陶红瓦
	Color(0.325, 0.400, 0.635),  ## 9  ROOF_BLUE 靛蓝瓦
	Color(0.361, 0.620, 0.718),  ## 10 WATER     水蓝
	Color(0.325, 0.533, 0.325),  ## 11 LEAF      树叶深绿
	Color(0.404, 0.286, 0.204),  ## 12 TRUNK     树干棕
	Color(0.855, 0.451, 0.204),  ## 13 FIRE      篝火橙
	Color(0.976, 0.729, 0.322),  ## 14 EMBER     亮橙
	Color(0.949, 0.769, 0.624),  ## 15 SKIN      肤色
	Color(0.706, 0.322, 0.310),  ## 16 CLOTH_A   赭红
	Color(0.318, 0.404, 0.647),  ## 17 CLOTH_B   靛蓝
	Color(0.369, 0.388, 0.435),  ## 18 METAL     深灰铁
	Color(0.945, 0.925, 0.867),  ## 19 CREAM     奶白
]

## 盒子 → 区域。转发 [method VoxelSkin.box]：护盾只有一份实现，
## 新用例不必再写一遍"以中心 + 尺寸书写"的辅助。
static func box(center: Vector3, size: Vector3, index: int) -> Dictionary:
	return VoxelSkin.box(center, size, index)


## 兜底区：覆盖整个局部包围盒并钉死索引。
static func all(bounds: AABB, index: int) -> Dictionary:
	return VoxelSkin.all(bounds, index)


## 一条水平色带 —— 楼层分色、屋顶分色最常用。
static func band_y(y0: float, y1: float, half_xz: float, index: int) -> Dictionary:
	return VoxelSkin.band_y(y0, y1, half_xz, index)


func _init() -> void:
	title = "用例二 · 中世纪村庄广场"


func palette() -> ToonPaletteDef:
	var p := ToonPaletteDef.new()
	p.title = title
	p.resource_name = title
	p.swatches = SWATCHES.duplicate()
	return apply_ramp(p,
		SWATCHES[GRASS], SWATCHES[CREAM],
		Color(0.502, 0.478, 0.588), Color(0.318, 0.290, 0.404),
		Color(0.180, 0.157, 0.216))
