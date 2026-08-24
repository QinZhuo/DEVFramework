@tool
class_name TownStreetStep extends TownStepDef
## 街具 — 路灯 + 长椅

@export_range(2, 16, 1) var streetlamp_spacing := 6


func apply(ctx: TownGenContext) -> void:
	var def: TownDef = ctx.def
	var layout := ctx.layout
	var roads := layout.roads_grid
	layout.streets = {"lamps": [], "benches": []}
	var walk := 0
	for y in roads.height:
		for x in roads.width:
			var rv := roads.get_cell(x, y, -1)
			if rv == def.road_main_value or rv == def.road_ring_value:
				walk += 1
				if walk % streetlamp_spacing == 0:
					layout.streets["lamps"].append(Vector2i(x, y))
