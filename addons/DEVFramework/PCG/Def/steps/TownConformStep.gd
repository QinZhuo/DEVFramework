@tool
class_name TownConformStep extends TownStepDef
## 地形回写（cut & fill）— 道路限坡松弛 + 切台锚点 + 羽化回写

@export_range(0.02, 0.3, 0.01) var road_max_grade := 0.1
@export_range(0, 6, 1) var terrace_blend := 3


func apply(ctx: TownGenContext) -> void:
	var def: TownDef = ctx.def
	var hm := ctx.heightmap
	if hm == null: return
	var roads := ctx.layout.roads_grid
	var build := ctx.layout.build_grid
	var w := roads.width; var n := w * roads.height
	# 1a 锚点收集: 建筑 ground_y + 广场均值
	var target := PackedFloat32Array(); target.resize(n); target.fill(INF)
	for b in ctx.layout.buildings:
		var gy: float = float(b.ground_y)
		for yy in range(b.rect.position.y, b.rect.end.y):
			for xx in range(b.rect.position.x, b.rect.end.x):
				target[yy * w + xx] = gy
	if not ctx.layout.plaza_cells.is_empty():
		var pavg := 0.0
		for idx in ctx.layout.plaza_cells: pavg += hm.heights[int(idx)]
		pavg /= float(ctx.layout.plaza_cells.size())
		for idx in ctx.layout.plaza_cells:
			target[int(idx)] = pavg
	# 1b 道路限坡松弛(24 pass 正反扫)
	var road_h := {}
	for i in n:
		if roads.cells[i] != 0: road_h[i] = hm.heights[i]
	var step := road_max_grade
	for _pass in 24:
		for rev in [false, true]:
			var xs := range(w); var ys := range(roads.height)
			if rev: xs.reverse(); ys.reverse()
			for yy in ys:
				for xx in xs:
					var ri: int = yy * w + xx
					if not road_h.has(ri): continue
					for d in [Vector2i(0,-1),Vector2i(1,0),Vector2i(0,1),Vector2i(-1,0)]:
						var ni: int = (yy+d.y)*w+(xx+d.x)
						if not road_h.has(ni): continue
						road_h[ri] = clampf(float(road_h[ri]), float(road_h[ni])-step, float(road_h[ni])+step)
	# 回写道路锚点
	for i in road_h: target[int(i)] = float(road_h[i])
	# 2 羽化回写：多源 BFS 从锚点向外携带目标高，随距离衰减
	var src_h := PackedFloat32Array(); src_h.resize(n); src_h.fill(INF)
	var dist2 := PackedInt32Array(); dist2.resize(n); dist2.fill(-1)
	var q2: Array[int] = []
	for i in n:
		if target[i] != INF: dist2[i]=0; src_h[i]=target[i]; q2.append(i)
	var head := 0
	while head < q2.size():
		var cur: int = q2[head]; head += 1
		var cx: int = cur % w; var cy: int = cur / w
		for d in [Vector2i(0,-1),Vector2i(1,0),Vector2i(0,1),Vector2i(-1,0)]:
			var ni: int = (cy+d.y)*w+(cx+d.x)
			if dist2[ni]!=-1 or dist2[cur]+1>terrace_blend: continue
			dist2[ni]=dist2[cur]+1; src_h[ni]=src_h[cur]; q2.append(ni)
	var sea := def.sea_level
	for i in n:
		var orig := hm.heights[i]
		if orig < sea and roads.get_cell(i%w, i/w, 0) != def.bridge_value: continue
		var t2 := target[i]
		if t2 != INF: hm.heights[i] = maxf(t2, sea-0.01)
		elif dist2[i] > 0:
			var k := 1.0 - float(dist2[i]) / float(terrace_blend+1)
			hm.heights[i] = maxf(lerpf(orig, src_h[i], clampf(k, 0.0, 1.0)), sea-0.01)
