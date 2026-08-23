@tool
class_name TownDef extends PCGGeneratorDef
## 城镇生成总控 — 可插拔步骤管线（替代原 CityDef 均匀网格填色器）
##
## steps 数组按序执行可插拔的 TownStepDef；留空使用内置标准链。
## 不同 steps 组合 + 参数 = 不同风格城镇（平原农耕镇/山地矿镇/渔村…）。
## 输出 ctx.output：key=TownLayout、key+_roads/_build 栅格、key+_site 选址点。
##
## 内置标准链：选址→路网→环路→巷道→广场→地块→建筑→室内→绿化→街具→农田→地形回写

@export_range(16, 512, 1) var width := 96
@export_range(16, 512, 1) var height := 96
## 从管线其它生成器取高度图（HeightMap）的 key；留空 = 平地城镇
@export var heightmap_key := ""
## 海平面（高度图水陆判定：低于此值为水）
@export_range(0.0, 1.0, 0.01) var sea_level := 0.5
## 归一高→世界格高的换算比例（渲染/导航共用）
@export_range(1.0, 24.0, 0.5) var height_scale := 8.0
## 城镇命名生成器（NAME 模式：前缀+后缀拼地名）；空 = 不命名
@export var name_gen: ContentGenDef

## —— 值语义（roads 层栅格） ——
@export var road_main_value := 3
@export var road_sec_value := 4
@export var road_alley_value := 5
@export var bridge_value := 6
@export var road_ring_value := 10

## —— 值语义（build 层栅格） ——
@export var building_wall_value := 7
@export var building_floor_value := 8
@export var building_door_value := 9
## 广场格值
@export var plaza_value := 11

## 允许跨水架桥（主街/环路共用；false 时道路绕开水面）
@export var bridge_allowed := true
## 跨水额外代价（越高越不愿架桥）
@export_range(1.0, 64.0, 0.5) var bridge_cost := 10.0

## —— 步骤参数容器（由 steps 数组中的同名参数在运行时同步进来；
##    直接调用 generate_town 时也可手动赋值） ——
## [选址]
@export_range(4, 128, 1) var site_candidates := 32
@export_range(2, 32, 1) var site_radius := 8
@export_range(0, 32, 1) var water_band_min := 3
@export_range(4, 96, 1) var water_band_max := 24
## [路网]
@export_range(1, 4, 1) var main_width := 2
@export_range(3, 24, 1) var street_spacing_min := 5
@export_range(4, 32, 1) var street_spacing_max := 9
@export_range(6, 128, 1) var secondary_max_len := 56
@export_range(0.0, 1.0, 0.01) var street_wander := 0.3
@export_range(0.0, 2.0, 0.05) var main_jitter := 0.4
@export_range(0.0, 4.0, 0.05) var slope_cost_k := 1.5
## [广场]
@export_range(0, 12, 1) var plaza_radius := 4
@export var plaza_feature := "水井"
## [地块]
@export_range(16, 1024, 4) var max_block_area := 260
@export_range(4, 128, 1) var min_block_area := 32
@export_range(16, 512, 2) var lot_max_area := 60
@export_range(4, 64, 1) var lot_min_area := 18
## [建筑]
@export var houses: Array[TemplateDef] = []
@export var facilities: Array[FacilityDef] = []
@export_range(0.0, 1.0, 0.01) var house_fill_ratio := 0.85
@export_range(0, 4, 1) var setback := 1
@export_range(1, 4, 1) var house_layers_min := 1
@export_range(1, 4, 1) var house_layers_max := 3
@export var house_roof := "gable"
@export var flat_roof_styles: Array[String] = ["石砌", "砖混"]
@export var style_table: Array[ContentEntryDef] = []
@export_range(0.02, 0.3, 0.01) var build_max_step := 0.08
## [室内]
@export var furniture_tables: Array[FurnitureTableDef] = []
@export var prop_table: Array[ContentEntryDef] = []
@export_range(0, 8, 1) var props_per_building := 3
## [绿化]
@export_range(0, 600, 5) var tree_count := 140
@export_range(1.0, 8.0, 0.5) var tree_min_distance := 2.5
@export_range(0, 16, 1) var street_tree_spacing := 5
## [街具]
@export_range(2, 16, 1) var streetlamp_spacing := 6
## [农田]
@export_range(4, 64, 1) var farm_min_dist := 14
@export_range(8, 512, 4) var farm_min_area := 60
## [回写]
@export_range(0.02, 0.3, 0.01) var road_max_grade := 0.1
@export_range(0, 6, 1) var terrace_blend := 3
## 是否执行地形回写（ConformStep 的 enabled 同样可控制）
@export var terrain_conform := true

## —— 可插拔步骤链（留空 = 内置标准链） ——
@export var steps: Array[TownStepDef] = []


func _to_string() -> String:
	return name


func get_desc(_data) -> String:
	return "城镇 %dx%d · %d 步骤" % [width, height, effective_steps().size()]


## 生效步骤链：steps 非空用配置，否则返回内置标准链
func effective_steps() -> Array[TownStepDef]:
	if not steps.is_empty():
		return steps
	return TownDef.default_steps()


## 内置标准链（每次调用生成新实例，资源间互不干扰）
static func default_steps() -> Array[TownStepDef]:
	var list: Array[TownStepDef] = []
	list.append(TownSiteStep.new())
	list.append(TownRoadStep.new())
	list.append(TownRingStep.new())
	list.append(TownAlleyStep.new())
	list.append(TownPlazaStep.new())
	list.append(TownParcelStep.new())
	list.append(TownBuildingStep.new())
	list.append(TownInteriorStep.new())
	list.append(TownGreeneryStep.new())
	list.append(TownStreetStep.new())
	list.append(TownFarmStep.new())
	list.append(TownConformStep.new())
	return list


func generate(ctx: PCGContext) -> void:
	var hm: HeightMap = null
	if not heightmap_key.is_empty():
		hm = ctx.get_result(heightmap_key) as HeightMap
	var gctx := TownGenContext.new(self, hm, int(ctx.rng.seed))
	gctx.layout.heightmap = hm
	# 城镇命名（独立种子槽，不随步骤增减变化）
	if name_gen != null:
		gctx.layout.town_name = PCGTool.generate_name(
			name_gen, PCGTool.make_rng(PCGTool.derive_seed(int(ctx.rng.seed), 10)))
	for s in effective_steps():
		if s == null or not s.enabled:
			continue
		s.apply(gctx)
	ctx.output[_effective_key()] = gctx.layout
	ctx.output[_effective_key() + "_roads"] = gctx.layout.roads_grid
	ctx.output[_effective_key() + "_build"] = gctx.layout.build_grid
	ctx.output[_effective_key() + "_site"] = gctx.layout.site
