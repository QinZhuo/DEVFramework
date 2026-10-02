class_name PCGSdfWorldTest
extends RefCounted

## 端到端回归 —— 「独立生成器 + 布局器」这条链路的整体性质
##
## 本测试不关心几何长什么样（那是 [PCGSdfGenTest]），只关心**结构性质**：
## 数量对不对、街道接不接得上、店铺朝不朝街道、会不会互相穿模、
## 以及最重要的一条：同样的 world_seed 必须摆出**一模一样**的世界。
##
## 为控制耗时，全部配方用低精度（体素 0.25~0.6）—— 结构性质与精度无关。
## 生产精度下的耗时量级见 SDF/Readme.md。

## 与主测试同一套配方，但只留 2 个单体，用于独立复现校验
const SMALL := [
	["street", "res://Scripts/Gen/StreetGen.gd", 1, 0, 0.35, 1],
	["shop", "res://Scripts/Gen/ShopGen.gd", 1, 1, 0.35, 2],
]


static func _recipe(tag: String, script: String, n: int, place: int, vs: float, kind: int) -> PropRecipe:
	var r := PropRecipe.new()
	r.tag = tag
	r.gen_script = load(script)
	r.count = n
	r.place = place
	r.voxel_size = vs
	r.kind_id = kind
	return r


static func _assembler() -> WorldAssembler:
	var a := WorldAssembler.new()
	a.add_recipe(_recipe("street", "res://Scripts/Gen/StreetGen.gd", 4, PropRecipe.Place.STREET, 0.35, 1))
	a.add_recipe(_recipe("shop", "res://Scripts/Gen/ShopGen.gd", 8, PropRecipe.Place.STREET_SIDE, 0.35, 2))
	a.add_recipe(_recipe("vehicle", "res://Scripts/Gen/VehicleGen.gd", 6, PropRecipe.Place.ROADSIDE, 0.25, 3))
	a.add_recipe(_recipe("hospital", "res://Scripts/Gen/HospitalGen.gd", 2, PropRecipe.Place.LANDMARK, 0.45, 4))
	## 测试地形：起伏 ±3m。街道若采样太稀就会明显穿模，这里正好能抓出来。
	a.ground_y = func(x: float, _z: float) -> float:
		return sin(x * 0.05) * 2.0 + 1.0
	return a


static func run() -> bool:
	var all_ok := true
	var seed_value := 20261002

	var asm := _assembler()
	var t0 := Time.get_ticks_msec()
	var ps := asm.assemble(seed_value)
	var ms := Time.get_ticks_msec() - t0

	# —— 1. 数量：配方说要几个就该有几个 ——
	var by_tag := {}
	var street := []
	for p in ps:
		var t: String = p.meta.get(&"tag", "?")
		by_tag[t] = int(by_tag.get(t, 0)) + 1
		if p.meta.get(&"is_street", false):
			street.append(p)
	var want := {"street": 4, "shop": 8, "vehicle": 6, "hospital": 2}
	var count_ok := ps.size() == 20
	for k in want:
		if int(by_tag.get(k, 0)) != int(want[k]):
			count_ok = false
	all_ok = all_ok and count_ok
	print("[世界] 数量: %s (共 %d, %s) 首次组装 %dms" % [count_ok, ps.size(), by_tag, ms])

	# —— 2. 街道首尾相接：段与段之间不能有缝（否则路面会露出缺口）——
	var chain_ok := street.size() == 4
	for i in range(1, street.size()):
		var gap: float = street[i].xform.origin.x - street[i - 1].xform.origin.x
		var want_gap: float = street[i - 1].build.footprint.x
		if absf(gap - want_gap) > 0.01:
			chain_ok = false
			print("[世界] 街道断开: 段%d 间距 %.3f 期望 %.3f" % [i, gap, want_gap])
	all_ok = all_ok and chain_ok
	print("[世界] 街道首尾相接: %s (x = %s)" % [chain_ok,
		street.map(func(p): return snappedf(p.xform.origin.x, 0.01))])

	# —— 3. 街道跟随地形：y 不能全一样，也不能全在 0 ——
	var ys := street.map(func(p): return snappedf(p.xform.origin.y, 0.01))
	var spread := 0.0
	for i in range(1, ys.size()):
		spread = maxf(spread, absf(float(ys[i]) - float(ys[i - 1])))
	var follow_ok := spread > 0.2
	all_ok = all_ok and follow_ok
	print("[世界] 街道随地形起伏: %s (y = %s, 最大落差 %.2f)" % [follow_ok, ys, spread])

	# —— 4. 店铺正面朝向街道：局部 +Z 应指向街道中线（z=0）——
	# 这条直接检验「布局器把朝向问题接过去了」—— 生成器自己只声明 face_dir。
	var face_ok := true
	for p in ps:
		if p.meta.get(&"tag", "") != "shop":
			continue
		var f: Vector3 = p.xform.basis * Vector3(0, 0, 1)
		var to_street := signf(-p.xform.origin.z)     # 指向 z=0 的方向
		if signf(f.z) != to_street:
			face_ok = false
	all_ok = all_ok and face_ok
	print("[世界] 店铺正面朝向街道: %s" % face_ok)

	# —— 5. 互不穿模 ——
	var free_ok := not PropLayoutTool.has_overlap(ps, 0.95)
	all_ok = all_ok and free_ok
	print("[世界] 全局避让后无重叠: %s" % free_ok)

	# —— 6. 确定性：同 world_seed 必须摆出同一个世界 ——
	# 用一个全新的组装器（清空 build 缓存）独立重烘，排除「其实读的是缓存」的假通过。
	var asm2 := WorldAssembler.new()
	for s in SMALL:
		asm2.add_recipe(_recipe(s[0], s[1], s[2], s[3], s[4], s[5]))
	asm2.ground_y = func(x: float, _z: float) -> float:
		return sin(x * 0.05) * 2.0 + 1.0
	var a := asm2.assemble(seed_value)
	var asm3 := WorldAssembler.new()
	for s in SMALL:
		asm3.add_recipe(_recipe(s[0], s[1], s[2], s[3], s[4], s[5]))
	asm3.ground_y = func(x: float, _z: float) -> float:
		return sin(x * 0.05) * 2.0 + 1.0
	var b := asm3.assemble(seed_value)
	var det := a.size() == b.size()
	for i in mini(a.size(), b.size()):
		if not a[i].xform.origin.is_equal_approx(b[i].xform.origin) or absf(a[i].yaw - b[i].yaw) > 1e-6:
			det = false
	all_ok = all_ok and det
	print("[世界] 同 world_seed 独立重烘结果一致: %s" % det)

	# 换 world_seed 必须换布局
	var c := asm2.assemble(seed_value + 1)
	var changed := false
	for i in mini(a.size(), c.size()):
		if not a[i].xform.origin.is_equal_approx(c[i].xform.origin):
			changed = true
			break
	all_ok = all_ok and changed
	print("[世界] 换 world_seed 布局改变: %s" % changed)

	# —— 7. 缓存：同 seed 不重复烘焙，重摆几乎免费 ——
	var t1 := Time.get_ticks_msec()
	var again := asm.assemble(seed_value)
	var cached_ms := Time.get_ticks_msec() - t1
	var same := again.size() == ps.size()
	for i in mini(again.size(), ps.size()):
		if not again[i].xform.origin.is_equal_approx(ps[i].xform.origin):
			same = false
	var cache_ok := same and asm._cache.size() == ps.size()
	all_ok = all_ok and cache_ok
	print("[世界] 缓存重摆: %s (%dms vs 首次 %dms, 缓存 %d 个单体)" % [
		cache_ok, cached_ms, ms, asm._cache.size()])

	# —— 8. 存档：只存 seed + 位置 + 朝向，不含网格 ——
	var rows := WorldAssembler.save_data(ps)
	var fields_ok := rows.size() == ps.size()
	for r in rows:
		if not (r.has(&"tag") and r.has(&"seed") and r.has(&"x") and r.has(&"y") \
				and r.has(&"z") and r.has(&"yaw")):
			fields_ok = false
		## 存档里绝不能出现网格/顶点数组 —— 出现就说明"世界数据吞并了单体内容"
		if r.size() != 6:
			fields_ok = false
	all_ok = all_ok and fields_ok
	print("[世界] 存档仅含 %d 字段/条(无网格): %s" % [rows[0].size() if rows.size() > 0 else 0, fields_ok])

	print("== SDF 世界组装测试 %s ==" % ("全部通过" if all_ok else "存在失败"))
	return all_ok
