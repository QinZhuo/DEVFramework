@tool
class_name CityDef extends PCGGeneratorDef
## 城镇生成器 — 小城镇完整管线总控（原均匀网格填色模式已删除）
##
## S1 地形评分选址 → S2 贴地道路网(主街坡度A*/次街扰动生长) →
## S2b 过大街区巷道分割 → S3 街区提取 → S4 临街地块细分；
## 建筑放置(M2)/室内家具(M3)后续接入。算法见 PCGTool.generate_town。
##
## 输出写入 ctx.output：
##   key          = TownLayout（选址+道路图+地块富实体）
##   key+"_roads" = GeneratedGrid 道路层（值语义：主街/次街/巷道/桥，均可配）
##   key+"_site"  = Vector2i 选址点

@export_range(16, 512, 1) var width := 96
@export_range(16, 512, 1) var height := 96
## 从管线其它生成器取高度图（HeightMap）的 key；留空 = 平地城镇
@export var heightmap_key := ""
## 海平面（高度图水陆判定：低于此值为水）
@export_range(0.0, 1.0, 0.01) var sea_level := 0.5

## —— S1 选址 ——
## 候选采样数（在最大陆地连通域内随机抽取打分）
@export_range(4, 128, 1) var site_candidates := 32
## 选址评分半径（格）：平坦度与陆地占比的考察范围
@export_range(2, 32, 1) var site_radius := 8
## 近水距离带下限（格）：比这更近视为有被淹风险扣分
@export_range(0, 32, 1) var water_band_min := 3
## 近水距离带上限（格）：比这更远视为缺水扣分
@export_range(4, 96, 1) var water_band_max := 24

## —— S2 道路网 ——
## 主街宽度（格）
@export_range(1, 4, 1) var main_width := 2
## 次街生长点沿主街的最小间距（格）
@export_range(3, 24, 1) var street_spacing_min := 6
## 次街生长点沿主街的最大间距（格）
@export_range(4, 32, 1) var street_spacing_max := 12
## 次街最大长度（步）
@export_range(6, 128, 1) var secondary_max_len := 40
## 次街随机弯折概率（0=直街，1=乱麻）
@export_range(0.0, 1.0, 0.01) var street_wander := 0.3
## 坡度代价系数：cost = 1 + k*Δh²（0=无视地形）
@export_range(0.0, 4.0, 0.05) var slope_cost_k := 1.5
## 允许跨水架桥（false 时道路绕开水面）
@export var bridge_allowed := true
## 跨水的额外代价（越高越不愿架桥）
@export_range(1.0, 64.0, 0.5) var bridge_cost := 10.0
## 是否修建城镇边界环路（沿道路覆盖范围外圈一圈路，收束路网）
@export var ring_road_enabled := true

## —— S3/S4 街区与地块 ——
## 街区面积超过此值则挖巷道分割
@export_range(16, 1024, 4) var max_block_area := 420
## 小于此面积的街区碎块忽略（转绿地由消费方处理）
@export_range(4, 128, 1) var min_block_area := 24
## 地块面积上限（超过则继续切分）
@export_range(16, 512, 2) var lot_max_area := 150
## 地块面积下限（小于丢弃）
@export_range(4, 64, 1) var lot_min_area := 18
## 地块长宽比软上限（影响切片终止）
@export_range(1.0, 8.0, 0.1) var lot_max_aspect := 4.0

## —— 值语义（roads 层栅格） ——
@export var road_main_value := 3
@export var road_sec_value := 4
@export var road_alley_value := 5
## 水上路段（桥）
@export var bridge_value := 6
## 边界环路（roads 层）
@export var road_ring_value := 10

## —— 广场 ——
## 选址点周围半径（格）内的空地划为广场（不放建筑，地块细分跳过）
@export_range(0, 12, 1) var plaza_radius := 4
## 广场格值（仅数据记录 layout.plaza_cells，渲染消费方按此着色；0=不启用）
@export var plaza_value := 11

## —— S5 建筑放置 ——
## 户型模板库（门字符 G 画在最底边墙上，旋转后门自动朝向临街边）
@export var houses: Array[TemplateDef] = []
## 功能设施表（酒馆/教堂/铁匠铺…：数量期望 + 主街偏好 + 专属户型）
@export var facilities: Array[FacilityDef] = []
## 其余地块的住宅填充比例
@export_range(0.0, 1.0, 0.01) var house_fill_ratio := 0.8
## 建筑足迹距地块边缘的退线（格）
@export_range(0, 4, 1) var setback := 1
## 建筑风格加权表（name=风格名；同街区邻近建筑倾向同风格）
@export var style_table: Array[ContentEntryDef] = []

## —— 建筑语义（跨项目成立的事实，渲染方据此解释外观） ——
## 住宅随机层数下限/上限
@export_range(1, 4, 1) var house_layers_min := 1
@export_range(1, 4, 1) var house_layers_max := 2
## 住宅默认屋顶类型（gable=双坡；渲染方按此查表选模型）
@export var house_roof := "gable"
## 这些风格强制平顶（如 石砌/砖混 搭配平顶更合理）
@export var flat_roof_styles: Array[String] = ["石砌", "砖混"]

## —— 值语义（build 层栅格） ——
@export var building_wall_value := 7
@export var building_floor_value := 8
@export var building_door_value := 9

## —— S6 室内布局 + 家具 ——
## 家具槽位表：slot_name=模板中的槽位字符，items=该槽位可抽的家具变体
@export var furniture_tables: Array[FurnitureTableDef] = []
## 自由装饰物加权表（散布在室内剩余空地）
@export var prop_table: Array[ContentEntryDef] = []
## 每栋建筑最多散布几个装饰物
@export_range(0, 8, 1) var props_per_building := 3

func generate(ctx: PCGContext) -> void:
	var hm: HeightMap = null
	if not heightmap_key.is_empty():
		hm = ctx.get_result(heightmap_key) as HeightMap
	var layout := PCGTool.generate_town(self, hm, int(ctx.rng.seed))
	ctx.output[_effective_key()] = layout
	ctx.output[_effective_key() + "_roads"] = layout.roads_grid
	ctx.output[_effective_key() + "_build"] = layout.build_grid
	ctx.output[_effective_key() + "_site"] = layout.site

func get_desc(_data) -> String:
	return "城镇 %dx%d" % [width, height]

func _to_string() -> String:
	return name
