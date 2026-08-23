class_name PCTTownReport extends RefCounted
## 城镇生成质量报告 — 多种子批量统计，输出调参依据
##
## 运行方式（编辑器执行，结果打印到日志）：
##   PCTTownReport.run()              # 默认 10 个种子
##   PCTTownReport.run(30, 12345)     # 自定义种子数与起始种子
##
## 指标：耗时 / 选址评分 / 建筑(POI 齐全率) / 地块临街率与利用率 /
##       门临路率 / 家具密度 / 广场·环路规模 / 主街连通性
## 全部达标输出 PASS，任一不达标列出 FAIL 项——作为调参前后的对比依据。

const DEFAULT_SEEDS := 10

static func run(seed_count := DEFAULT_SEEDS, seed_start := 20260101) -> Dictionary:
	var city := load("res://Assets/Def/PCG/City_Grid.tres") as CityDef
	if city == null:
		push_error("PCTTownReport: 找不到 City_Grid.tres")
		return {}
	var rows: Array = []
	var all_pass := true
	print("== 城镇质量报告 (%d 种子, %dx%d) ==" % [seed_count, city.width, city.height])
	print("seed    ms    site  bld  poi  door%  lot%  furn  plaza ring  conn")
	for i in seed_count:
		var seed := seed_start + i * 7919
		var t0 := Time.get_ticks_usec()
		var tl := PCGTool.generate_town(city, null, seed)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		var r := _measure(city, tl, ms, seed)
		rows.append(r)
		all_pass = all_pass and r.pass_all
		print("%d %5.0f  %s  %3d  %3d  %5.1f  %5.1f  %4d  %4d  %4d  %s" % [
			seed, r.ms, str(r.site), r.buildings, r.poi, r.door_rate * 100.0,
			r.lot_use * 100.0, r.furniture, r.plaza, r.ring, "OK" if r.connected else "FAIL"])
	var summary := _summarize(rows)
	print("---- 汇总 (均值) ----")
	print("建筑 %.1f | POI %.1f | 门临路 %.1f%% | 地块利用 %.1f%% | 家具 %.1f | 耗时 %.0fms" % [
		summary.buildings, summary.poi, summary.door_rate * 100.0,
		summary.lot_use * 100.0, summary.furniture, summary.ms])
	if not summary.poi_names.is_empty():
		print("设施类型齐全率: %d/%d" % [summary.poi_kinds_present, summary.poi_names.size()])
	var fail_lines: Array = []
	for r in rows:
		for f in r.fails:
			fail_lines.push_back("seed%d: %s" % [r.seed, f])
	if fail_lines.is_empty():
		print("== 质量报告 PASS (%d/%d) ==" % [rows.size(), rows.size()])
	else:
		print("== 质量报告 FAIL (%d 项问题) ==" % fail_lines.size())
		for line in fail_lines:
			print("  " + String(line))
	return {"rows": rows, "pass": all_pass}


static func _measure(city: CityDef, tl: TownLayout, ms: float, seed: int) -> Dictionary:
	var fails: Array = []
	var rg := tl.roads_grid
	# 门临路率（含边界环路）
	var door_ok := 0
	for b in tl.buildings:
		var dr: Vector2i = b.door
		for d in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
			var rv := rg.get_cell(dr.x + d.x, dr.y + d.y, -9)
			if rv == city.road_main_value or rv == city.road_sec_value \
					or rv == city.road_alley_value or rv == city.road_ring_value \
					or rv == city.bridge_value:
				door_ok += 1
				break
	var door_rate := float(door_ok) / maxf(1.0, float(tl.buildings.size()))
	if door_rate < 0.99:
		fails.push_back("门临路率 %.0f%% < 99%%" % (door_rate * 100.0))
	# POI 齐全率（facilities 表里每类至少 1 栋）
	var poi := 0
	var present := {}
	for b in tl.buildings:
		if String(b.type) != "住宅":
			poi += 1
			present[String(b.type)] = true
	var missing: Array = []
	for fac in city.facilities:
		if fac != null and not present.has(String(fac.facility_name)):
			missing.push_back(String(fac.facility_name))
	if not missing.is_empty():
		fails.push_back("缺设施: " + ", ".join(missing))
	# 地块利用率：建筑足迹格 / 临街地块总格
	var lot_cells := 0
	var build_cells := _count_build_cells(city, tl)
	for p in tl.parcels:
		lot_cells += int((p.cells as PackedInt32Array).size())
	var lot_use := float(build_cells) / maxf(1.0, float(lot_cells))
	# 主街连通（site 沿路可达边缘）
	var connected := _check_connected(tl, rg.width, rg.height)
	if not connected:
		fails.push_back("主街不连通")
	var furniture := 0
	for k in tl.interiors:
		furniture += (tl.interiors[k].slots as Array).size()
	return {
		"seed": seed, "ms": ms, "site": str(tl.site), "score": tl.site_score,
		"buildings": tl.buildings.size(), "poi": poi,
		"missing_poi": missing, "poi_names": _facility_names(city),
		"poi_kinds_present": present.size(),
		"door_rate": door_rate, "lot_use": lot_use,
		"furniture": furniture, "plaza": tl.plaza_cells.size(),
		"ring": rg.count(city.road_ring_value),
		"connected": connected, "fails": fails, "pass_all": fails.is_empty(),
	}


static func _count_build_cells(_city: CityDef, tl: TownLayout) -> int:
	var n := 0
	for b in tl.buildings:
		n += int(b.rect.size.x) * int(b.rect.size.y)
	return n


static func _facility_names(city: CityDef) -> Array[String]:
	var names: Array[String] = []
	for fac in city.facilities:
		if fac != null:
			names.append(String(fac.facility_name))
	return names


## site 沿道路格 BFS 是否触达地图边缘
static func _check_connected(tl: TownLayout, w: int, h: int) -> bool:
	var rg := tl.roads_grid
	var seen := {tl.site: true}
	var queue: Array[Vector2i] = [tl.site]
	while not queue.is_empty():
		var c: Vector2i = queue.pop_back()
		if c.x == 0 or c.y == 0 or c.x == w - 1 or c.y == h - 1:
			return true
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx := c + d
			if rg.in_bounds(nx.x, nx.y) and rg.get_cell(nx.x, nx.y, 0) != 0 and not seen.has(nx):
				seen[nx] = true
				queue.append(nx)
	return false


## 各指标均值汇总行
static func _summarize(rows: Array) -> Dictionary:
	var n := maxf(1.0, float(rows.size()))
	var sum := {"ms": 0.0, "buildings": 0.0, "poi": 0.0, "door_rate": 0.0, "lot_use": 0.0, "furniture": 0.0}
	var kinds := 0
	var names: Array[String] = []
	for r in rows:
		for k in sum:
			sum[k] += float(r[k])
		kinds = maxi(kinds, int(r.poi_kinds_present))
		names = r.poi_names
	for k in sum:
		sum[k] = sum[k] / n
	sum["poi_kinds_present"] = kinds
	sum["poi_names"] = names
	return sum
