@tool
class_name TownInteriorStep extends TownStepDef
## 室内家具 + 院落围栏

@export var furniture_tables: Array[FurnitureTableDef] = []
@export var prop_table: Array[ContentEntryDef] = []
@export_range(0, 8, 1) var props_per_building := 3


func apply(ctx: TownGenContext) -> void:
	var def: TownDef = ctx.def
	var layout := ctx.layout
	if furniture_tables.is_empty() or layout.build_grid == null: return
	var tables := {}
	for ft in furniture_tables:
		if ft != null and not ft.slot_name.is_empty() and not ft.items.is_empty():
			tables[ft.slot_name] = ft.items
	var rng := ctx.next_rng()
	var build := layout.build_grid
	for b in layout.buildings:
		var slots: Array = []; var occupied := {}
		for yy in range(b.rect.position.y, b.rect.end.y):
			for xx in range(b.rect.position.x, b.rect.end.x):
				var v := build.get_cell(xx, yy, -1)
				if v != def.building_floor_value: continue
				for slot_ch in tables:
					var r := rng.randf()
					if r < 0.3:
						slots.append({"cell": Vector2i(xx, yy), "item": PCGTool.pick_weighted(rng, tables[slot_ch]).name})
						occupied[Vector2i(xx, yy)] = true
						break
		var props: Array = []
		var free: Array[Vector2i] = []
		for yy in range(b.rect.position.y, b.rect.end.y):
			for xx in range(b.rect.position.x, b.rect.end.x):
				var c := Vector2i(xx, yy)
				if build.get_cell(xx, yy, -1) == def.building_floor_value and not occupied.has(c):
					free.append(c)
		for _i in mini(props_per_building, free.size()):
			if prop_table.is_empty(): break
			var fi := rng.randi_range(0, free.size() - 1)
			props.append({"cell": free[fi], "item": PCGTool.pick_weighted(rng, prop_table).name})
			free.remove_at(fi)
		layout.interiors[int(b.id)] = {"slots": slots, "props": props}
