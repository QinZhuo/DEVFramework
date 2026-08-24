@tool
class_name TownBuildingStep extends TownStepDef
## 建筑放置 — 设施优先 + 住宅填充 + 锚点定位(门贴路) + 分向退线

@export var houses: Array[TemplateDef] = []
@export var facilities: Array[FacilityDef] = []
@export_range(0.0, 1.0, 0.01) var house_fill_ratio := 0.85
@export_range(1, 4, 1) var house_layers_min := 1
@export_range(1, 4, 1) var house_layers_max := 3
@export var house_roof := "gable"
@export var style_table: Array[ContentEntryDef] = []
@export_range(0.02, 0.3, 0.01) var build_max_step := 0.08


func apply(ctx: TownGenContext) -> void:
	var def: TownDef = ctx.def
	var layout := ctx.layout
	if houses.is_empty(): return
	layout.build_grid = GeneratedGrid.create(def.width, def.height, 0)
	var rng := ctx.next_rng()
	var used := {}; var bid := 0
	for fac in facilities:
		if fac == null: continue
		var count := int(maxf(fac.count, 0.0))
		if rng.randf() < maxf(fac.count, 0.0) - float(count): count += 1
		for _k in count:
			var li := _best_lot(def, layout, used, rng)
			if li < 0: break
			if _place_one(def, layout, li, fac.facility_name, bid, fac, rng):
				used[li] = true; bid += 1
	for pi in layout.parcels.size():
		if used.has(pi): continue
		if rng.randf() > house_fill_ratio: continue
		if _place_one(def, layout, pi, "住宅", bid, null, rng):
			bid += 1


func _best_lot(layout: TownLayout, used: Dictionary, rng: RandomNumberGenerator) -> int:
	var best := -1; var best_n := -1
	for li in layout.parcels.size():
		if used.has(li): continue
		var p = layout.parcels[li]
		var n: int = (p.cells as PackedInt32Array).size()
		if n > best_n: best_n = n; best = li
	return best


func _place_one(def: TownDef, layout: TownLayout, li: int, type_name: String,
		bid: int, fac: FacilityDef, rng: RandomNumberGenerator) -> bool:
	var parcel: Dictionary = layout.parcels[li]
	var facing := int(parcel.frontage_dir)
	if facing < 0: return false
	var rect: Rect2i = parcel.rect
	var aw := rect.size.x - 2; var ah := rect.size.y - 2
	if aw <= 0 or ah <= 0: return false
	var layers := clampi(fac.layers if fac else rng.randi_range(house_layers_min, house_layers_max), 1, 4)
	var roof := fac.roof if fac else house_roof
	# 选适配模板
	var tmpl: TemplateDef = null
	var best_diff := INF
	for t in def.houses:
		if t == null: continue
		var sz := t.get_size()
		var diff := absi(sz.x * sz.y - aw * ah)
		if sz.x <= aw and sz.y <= ah and diff < best_diff:
			best_diff = diff; tmpl = t
	if tmpl == null: return false
	var rot := _rot_for(facing)
	var sz2 := tmpl.get_rotated_size(rot)
	var fw := sz2.x; var fh := sz2.y
	# 锚点：临街格反推位置
	var roads := layout.roads_grid
	var dir_v: Vector2i = [Vector2i(0,-1),Vector2i(1,0),Vector2i(0,1),Vector2i(-1,0)][facing]
	var build := layout.build_grid
	var door_off := Vector2i(-1,-1); var tsz := tmpl.get_size()
	for ly in tmpl.lines.size():
		var lx := tmpl.lines[ly].find("G")
		if lx >= 0:
			door_off = TownGenTool.rot_point(Vector2i(lx, ly), tsz, rot); break
	if door_off.x < 0: return false
	var anchors: Array[Vector2i] = []
	for idx in parcel.cells:
		var ax: int = int(idx) % def.width
		var ay: int = int(idx) / def.width
		if roads.get_cell(ax + dir_v.x, ay + dir_v.y, -1) > 0:
			anchors.append(Vector2i(ax, ay) - door_off)
	while not anchors.is_empty():
		var ai := rng.randi_range(0, anchors.size() - 1)
		var pos: Vector2i = anchors[ai]; anchors.remove_at(ai)
		if pos.x < rect.position.x or pos.y < rect.position.y: continue
		if pos.x + fw > rect.end.x or pos.y + fh > rect.end.y: continue
		var ok := true
		for yy in range(pos.y, pos.y + fh):
			for xx in range(pos.x, pos.x + fw):
				if roads.get_cell(xx, yy, -1) != 0 or build.get_cell(xx, yy, -1) != 0:
					ok = false; break
			if not ok: break
		if not ok: continue
		# 印模板
		var mapping := {"#": def.building_wall_value, "G": def.building_door_value}
		for yy2 in range(pos.y, pos.y + fh):
			for xx2 in range(pos.x, pos.x + fw):
				build.set_cell(xx2, yy2, def.building_floor_value)
		for ly2 in tmpl.lines.size():
			var line := tmpl.lines[ly2]
			for lx2 in line.length():
				var ch := line[lx2]
				if mapping.has(ch):
					var np2 := TownGenTool.rot_point(Vector2i(lx2, ly2), tsz, rot)
					build.set_cell(pos.x + np2.x, pos.y + np2.y, int(mapping[ch]))
		var door := Vector2i(-1,-1)
		for yy3 in range(pos.y, pos.y+fh):
			for xx3 in range(pos.x, pos.x+fw):
				if build.get_cell(xx3,yy3,-1)==def.building_door_value: door=Vector2i(xx3,yy3); break
			if door.x>=0: break
		if door.x<0: door=Rect2i(pos.x,pos.y,fw,fh).get_center(); build.set_cell(door.x,door.y,def.building_floor_value)
		layout.buildings.append({"id":bid,"type":type_name,"style":"","rect":Rect2i(pos.x,pos.y,fw,fh),"door":door,"facing":facing})
		return true
	return false


func _rot_for(facing: int) -> int:
	match facing:
		1: return 3
		3: return 1
		0: return 2
	return 0
