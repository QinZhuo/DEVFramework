@tool
class_name TownParcelStep extends TownStepDef
## 临街地块细分

@export_range(16, 1024, 4) var max_block_area := 260
@export_range(4, 128, 1) var min_block_area := 32
@export_range(16, 512, 2) var lot_max_area := 60
@export_range(4, 64, 1) var lot_min_area := 18


func apply(ctx: TownGenContext) -> void:
	var def: TownDef = ctx.def
	var roads := ctx.layout.roads_grid
	var rng := ctx.next_rng()
	for block in _blocks(roads):
		if block.size() < def.min_block_area:
			continue
		var rect := _bounds(block, roads.width)
		var cells := {}
		for idx in block:
			cells[int(idx)] = true
		_slice(def, roads, cells, rect, 0, rng, ctx.layout.parcels)


func _blocks(roads: GeneratedGrid) -> Array[PackedInt32Array]:
	var sep := GeneratedGrid.create(roads.width, roads.height, 0)
	for i in sep.cells.size():
		sep.cells[i] = 1 if roads.cells[i] != 0 else 0
	return sep.components(0)


func _bounds(cells: PackedInt32Array, w: int) -> Rect2i:
	var mn := Vector2i(2147483647, 0); var mx := Vector2i(0, 0)
	for idx in cells:
		var p := Vector2i(int(idx) % w, int(idx) / w)
		if mn.x > p.x: mn.x = p.x
		if mx.x < p.x: mx.x = p.x
		if mn.y > p.y: mn.y = p.y
		if mx.y < p.y: mx.y = p.y
	return Rect2i(mn, mx - mn + Vector2i.ONE)


func _slice(def: TownDef, roads: GeneratedGrid, cells: Dictionary, rect: Rect2i,
		depth: int, rng: RandomNumberGenerator, out: Array) -> void:
	if depth > 14: return
	var area := cells.size()
	if area < def.lot_min_area: return
	if area <= def.lot_max_area:
		var f := _frontage(roads, cells)
		if f >= 0:
			out.append({"rect": rect, "cells": PackedInt32Array(cells.keys()), "frontage_dir": f})
		return
	var ra: Rect2i; var rb: Rect2i
	if rect.size.x >= rect.size.y:
		var sx := rect.position.x + maxi(1, int(rect.size.x * rng.randf_range(0.35, 0.65)))
		ra = Rect2i(rect.position, Vector2i(sx - rect.position.x, rect.size.y))
		rb = Rect2i(Vector2i(sx, rect.position.y), Vector2i(rect.end.x - sx, rect.size.y))
	else:
		var sy := rect.position.y + maxi(1, int(rect.size.y * rng.randf_range(0.35, 0.65)))
		ra = Rect2i(rect.position, Vector2i(rect.size.x, sy - rect.position.y))
		rb = Rect2i(Vector2i(rect.position.x, sy), Vector2i(rect.size.x, rect.end.y - sy))
	for half in [ra, rb]:
		var sub := {}
		for idx in cells:
			var x: int = int(idx) % roads.width; var y: int = int(idx) / roads.width
			if x >= half.position.x and x < half.end.x and y >= half.position.y and y < half.end.y:
				sub[idx] = true
		if not sub.is_empty():
			_slice(def, roads, sub, half, depth + 1, rng, out)


func _frontage(roads: GeneratedGrid, cells: Dictionary) -> int:
	var counts := [0, 0, 0, 0]
	for idx in cells:
		var x: int = int(idx) % roads.width; var y: int = int(idx) / roads.width
		for di in 4:
			var d: Vector2i = [Vector2i(0,-1),Vector2i(1,0),Vector2i(0,1),Vector2i(-1,0)][di]
			if roads.get_cell(x + d.x, y + d.y, -1) != 0:
				counts[di] += 1
	var best := -1; var bn := 0
	for di in 4:
		if counts[di] > bn: bn = counts[di]; best = di
	return best
