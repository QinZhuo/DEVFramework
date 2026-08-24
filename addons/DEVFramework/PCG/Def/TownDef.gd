@tool
class_name TownDef extends PCGGeneratorDef
## 城镇生成总控 — 可插拔步骤管线
##
## 只保留全局配置（尺寸/海平面/值语义/命名器）+ steps 数组。
## 步骤参数在各 Step Def 资源上自包含，不同组合 = 不同风格城镇。
## 输出 ctx.output：key=TownLayout、key+_roads/_build 栅格、key+_site 选址点。

@export_range(16, 512, 1) var width := 96
@export_range(16, 512, 1) var height := 96
@export var heightmap_key := ""
@export_range(0.0, 1.0, 0.01) var sea_level := 0.5
@export_range(1.0, 24.0, 0.5) var height_scale := 8.0
@export var name_gen: ContentGenDef

@export_group("值语义: roads 层")
@export var road_main_value := 3
@export var road_sec_value := 4
@export var road_alley_value := 5
@export var bridge_value := 6
@export var road_ring_value := 10

@export_group("值语义: build 层")
@export var building_wall_value := 7
@export var building_floor_value := 8
@export var building_door_value := 9
@export var plaza_value := 11

@export_group("桥规则")
@export var bridge_allowed := true
@export_range(1.0, 64.0, 0.5) var bridge_cost := 10.0

@export_group("城镇步骤链")
## 可插拔步骤（留空 = 内置标准链）
@export var steps: Array[TownStepDef] = []


func _to_string() -> String:
	return name


func get_desc(_data) -> String:
	return "城镇 %dx%d · %d 步骤" % [width, height, effective_steps().size()]


func effective_steps() -> Array[TownStepDef]:
	if not steps.is_empty():
		return steps
	return TownDef.default_steps()


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
