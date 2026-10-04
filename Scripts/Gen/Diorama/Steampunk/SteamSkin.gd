@tool
class_name SteamSkin
extends DioramaSkin
## 用例五「蒸汽朋克飞艇码头工坊」的固定 18 色板
##
## ## 取色纪律
## 蒸汽朋克的配色是**金属主导 + 一冷一暖两个对比**：
## · 黄铜（0.85/0.68/0.32）是全场主色，它偏暖、明度高，占面积最大；
## · 铁件（0.32/0.33/0.38）刻意压到**偏冷的深灰**而不是褐色 ——
##   这样"铜"与"铁"在色阶里分得开，而不是两种棕分不清；
## · 皮革（0.36/0.22/0.16）比木头更红、更沉，气囊才不会跟码头木板糊在一起；
## · 蒸汽（0.92/0.93/0.95）与炉火（0.96/0.55/0.20）是唯一的两个高明度色，
##   全场的"视觉焦点"就靠它们，所以别的东西一律不许再往亮里走。
##
## 0 号是主体色且用作兜底（[DioramaSkin] 的通用纪律）：这里是 [constant BRASS]，
## 因为"黄铜"是这套美学唯一的定义性特征，漏配的零件落到它身上最说得通。

#region 部位索引

const BRASS := 0       ## 抛光黄铜：飞艇外壳、管道、仪表壳（主体色）
const BRASS_DK := 1    ## 暗铜：齿轮、阀门、阴影侧
const IRON := 2        ## 做旧铁：支架、铁轨、铰链
const RUST := 3        ## 铁锈：铁件的受蚀面
const WOOD := 4        ## 深棕木：码头桩、工具箱
const WOOD_LT := 5     ## 浅木：码头甲板板
const LEATHER := 6     ## 深棕皮革：气囊主体
const LEATHER_HI := 7  ## 皮革受光：气囊上表面
const GLASS := 8       ## 玻璃：观察窗、压力表表盘
const COAL := 9        ## 煤黑：煤堆、炉膛
const COAL_HI := 10    ## 煤块受光面
const COPPER := 11     ## 紫铜：细管道、线圈
const STEAM := 12      ## 蒸汽白：喷嘴雾气
const EMBER := 13      ## 炉火橙：炉门透出的火光
const GAUGE := 14      ## 仪表白：压力表刻度盘
const LAMP := 15       ## 灯笼暖黄
const ROPE := 16       ## 麻绳：系缆、吊索
const WATER := 17      ## 水面暗蓝：码头下的水

#endregion

const SWATCHES: Array[Color] = [
	Color(0.851, 0.678, 0.322),  ## 0  BRASS      抛光黄铜
	Color(0.545, 0.412, 0.180),  ## 1  BRASS_DK   暗铜
	Color(0.318, 0.333, 0.380),  ## 2  IRON       做旧铁
	Color(0.451, 0.259, 0.157),  ## 3  RUST       铁锈
	Color(0.310, 0.216, 0.157),  ## 4  WOOD       深棕木
	Color(0.596, 0.451, 0.290),  ## 5  WOOD_LT    浅木
	Color(0.361, 0.220, 0.161),  ## 6  LEATHER    深棕皮革
	Color(0.541, 0.353, 0.235),  ## 7  LEATHER_HI 皮革受光
	Color(0.616, 0.769, 0.800),  ## 8  GLASS      玻璃
	Color(0.157, 0.145, 0.161),  ## 9  COAL       煤黑
	Color(0.298, 0.290, 0.318),  ## 10 COAL_HI    煤块受光
	Color(0.769, 0.412, 0.267),  ## 11 COPPER     紫铜
	Color(0.918, 0.929, 0.949),  ## 12 STEAM      蒸汽白
	Color(0.957, 0.549, 0.196),  ## 13 EMBER      炉火橙
	Color(0.878, 0.855, 0.792),  ## 14 GAUGE      仪表白
	Color(1.000, 0.847, 0.541),  ## 15 LAMP       灯笼暖黄
	Color(0.678, 0.596, 0.443),  ## 16 ROPE       麻绳
	Color(0.204, 0.278, 0.353),  ## 17 WATER      水面暗蓝
]

static func box(center: Vector3, size: Vector3, index: int) -> Dictionary:
	return VoxelSkin.box(center, size, index)

static func all(bounds: AABB, index: int) -> Dictionary:
	return VoxelSkin.all(bounds, index)

static func band_y(y0: float, y1: float, half_xz: float, index: int) -> Dictionary:
	return VoxelSkin.band_y(y0, y1, half_xz, index)

func _init() -> void:
	title = "用例五 · 飞艇码头工坊"

func palette() -> ToonPaletteDef:
	var p := ToonPaletteDef.new()
	p.title = title
	p.resource_name = title
	p.swatches = SWATCHES.duplicate()
	## 亮档 ramp **不能用 STEAM 白**：[ToonStyleDef.make_material] 的亮档是
	## `base.lerp(light, 0.55)` —— 拿 (0.92,0.93,0.95) 的白去混，
	## 黄铜 (0.85,0.68,0.32) 的橙味剩不到一半，整幅画就只剩"米白 + 暗紫"两色
	## （实测：甲板顶与气囊顶全成白纸，暖铜味荡然无存）。
	## 亮档必须是**黄铜自己的提亮版**，白留给 spec 高光与蒸汽口。
	return apply_ramp(p,
		SWATCHES[BRASS], Color(0.976, 0.863, 0.549),
		Color(0.451, 0.376, 0.310), Color(0.259, 0.204, 0.196),
		Color(0.129, 0.098, 0.110))
