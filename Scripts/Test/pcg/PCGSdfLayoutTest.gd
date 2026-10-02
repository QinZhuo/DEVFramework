class_name PCGSdfLayoutTest
extends RefCounted

## SDF 世界布局（PropLayoutTool 层）回归测试
##
## 覆盖布局层的全部职责边界：贴地 / 朝向 / 避让 / 存档。
## 它**不做**的事（造型决策）由 PCGSdfGenTest 负责。
##
## 注意本文件全程不生成任何真实几何 —— 布局层只读 PropBuild 的
## bounds / footprint / meta，网格是摆设。夹具直接手搓一个最小
## PropBuild，这本身就是"布局层不认识几何细节"的可执行证明：
## 若哪天 PropLayoutTool 开始依赖 mesh 顶点，这里的夹具会立刻失效。

## 测试用斜坡：地面高度只随 x 变化，斜率 0.5
const SLOPE := 0.5

## 占地 fp（米），局部原点 y=0 起算
static func _build(fp := Vector2(6, 8), meta := {}) -> PropBuild:
	var b := PropBuild.new()
	var mesh := SdfMesh.new()
	mesh.vertices = PackedVector3Array([Vector3.ZERO, Vector3(1, 0, 0), Vector3(0, 0, 1)])
	mesh.indices = PackedInt32Array([0, 1, 2])
	mesh.local_aabb = AABB(Vector3.ZERO, Vector3(fp.x, 3.5, fp.y))
	b.mesh = mesh
	b.bounds = mesh.local_aabb
	b.footprint = fp
	b.meta = meta
	return b


## 斜坡地面查询：h(x, z) = SLOPE * x
## 用 lambda 而非 Callable(类名, ...) —— 加载期自身 class_name 尚未注册，不可靠。
static func _ground() -> Callable:
	return func(x: float, _z: float) -> float:
		return SLOPE * x


static func run() -> bool:
	var all_ok := true
	var b := _build()
	var g := _ground()

	# —— 1. 贴地模式 ——
	# 建筑中心 (10, 0)，占地 6×8、yaw=0 → 采样点 x ∈ {7, 13, 7, 13, 10}
	#   地面高   ∈ {3.5, 6.5, 3.5, 6.5, 5.0} → lo=3.5 hi=6.5 avg=5.0
	# 局部 y 从 0 起算（bounds.position.y = 0）→ lift = 0，故 origin.y 即地面高。
	var cases := [
		[PropLayoutTool.Snap.MIN, 3.5, "MIN(宁陷勿浮)"],
		[PropLayoutTool.Snap.MAX, 6.5, "MAX(宁悬勿陷)"],
		[PropLayoutTool.Snap.CENTER, 5.0, "CENTER(取平均)"],
	]
	for c in cases:
		var p := PropLayoutTool.solve(b, 1, Vector2(10, 0), 0.0, g, {&"snap": c[0]})
		var ok := p != null and p.snapped and absf(p.xform.origin.y - float(c[1])) < 0.001
		all_ok = all_ok and ok
		print("[布局] 贴地 %s: y=%.3f 期望=%.3f ok=%s" % [c[2], p.xform.origin.y if p else NAN, c[1], ok])

	# 不贴地：y=0，snapped=false
	var p_none := PropLayoutTool.solve(b, 1, Vector2(10, 0), 0.0, g, {&"snap": PropLayoutTool.Snap.NONE})
	var none_ok := is_zero_approx(p_none.xform.origin.y) and not p_none.snapped
	all_ok = all_ok and none_ok
	print("[布局] 贴地 NONE: y=%.3f snapped=%s ok=%s" % [p_none.xform.origin.y, p_none.snapped, none_ok])

	# 无地面信息 → 退化为 NONE（框架不认识任何地形类，靠鸭子类型拿地面）
	var p_nog := PropLayoutTool.solve(b, 1, Vector2(10, 0), 0.0, Callable(), {&"snap": PropLayoutTool.Snap.MIN})
	var nog_ok := is_zero_approx(p_nog.xform.origin.y) and not p_nog.snapped
	all_ok = all_ok and nog_ok
	print("[布局] 无 ground_y 退化为 NONE: ok=%s" % nog_ok)

	# meta.surface_snap 缺省路径：不传 snap 时按生成器自报决定
	var p_auto := PropLayoutTool.solve(_build(Vector2(6, 8), {&"surface_snap": true}), 1,
		Vector2(10, 0), 0.0, g, {})
	var auto_ok := p_auto.snapped and absf(p_auto.xform.origin.y - 3.5) < 0.001
	all_ok = all_ok and auto_ok
	print("[布局] 按 meta.surface_snap 自动贴地: y=%.3f ok=%s" % [p_auto.xform.origin.y, auto_ok])

	# y_offset：额外抬高
	var p_off := PropLayoutTool.solve(b, 1, Vector2(10, 0), 0.0, g,
		{&"snap": PropLayoutTool.Snap.MIN, &"y_offset": 1.25})
	var off_ok := absf(p_off.xform.origin.y - 4.75) < 0.001
	all_ok = all_ok and off_ok
	print("[布局] y_offset 叠加: y=%.3f ok=%s" % [p_off.xform.origin.y, off_ok])

	# 不可放点 → null（选址阶段的过滤）
	var blocked := func(_x: float, _z: float) -> bool: return true
	var p_blk := PropLayoutTool.solve(b, 1, Vector2(10, 0), 0.0, g, {&"blocked": blocked})
	var blk_ok := p_blk == null
	all_ok = all_ok and blk_ok
	print("[布局] blocked 点位被拒: %s" % blk_ok)

	# —— 2. 朝向 ——
	# yaw_to_face：局部正面 (0,0,1) 转向世界 +X 应得 +90°
	var y_x := PropLayoutTool.yaw_to_face(Vector2(1, 0), Vector3i(0, 0, 1))
	var y_z := PropLayoutTool.yaw_to_face(Vector2(0, 1), Vector3i(0, 0, 1))
	var y_nx := PropLayoutTool.yaw_to_face(Vector2(-1, 0), Vector3i(0, 0, 1))
	var math_ok := absf(y_x - PI * 0.5) < 1e-4 and absf(y_z) < 1e-4 and absf(absf(y_nx) - PI * 0.5) < 1e-4
	all_ok = all_ok and math_ok
	print("[布局] yaw_to_face 数学: +X=%.3f +Z=%.3f -X=%.3f ok=%s" % [y_x, y_z, y_nx, math_ok])

	# align_dir 端到端：正面实际应指向给定世界方向
	for dir in [Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0), Vector2(0, -1), Vector2(1, 1).normalized()]:
		var p := PropLayoutTool.solve(b, 1, Vector2.ZERO, 0.0, Callable(),
			{&"align_dir": dir, &"face_dir": Vector3i(0, 0, 1)})
		var f: Vector3 = p.xform.basis * Vector3(0, 0, 1)
		var ok := Vector2(f.x, f.z).normalized().is_equal_approx(dir)
		all_ok = all_ok and ok
		print("[布局] 正面朝向 %s: ok=%s" % [dir, ok])

	# —— 3. 避让（OBB + 分离轴）——
	# 两栋 6×8 建筑，中心相距 2m —— 初始重叠 4m
	var ps := [
		PropLayoutTool.solve(_build(), 1, Vector2(0, 0), 0.0, Callable(), {}),
		PropLayoutTool.solve(_build(), 2, Vector2(2, 0), 0.0, Callable(), {}),
	]
	var pre := PropLayoutTool.has_overlap(ps, 1.0)
	PropLayoutTool.relax(ps, 32, 1.0)
	var post := PropLayoutTool.has_overlap(ps, 1.0)
	var sep_ok := pre and not post
	all_ok = all_ok and sep_ok
	print("[布局] 同向重叠松弛: 重叠=%s → 松弛后重叠=%s 间距=%.3f ok=%s" % [
		pre, post, ps[0].xform.origin.distance_to(ps[1].xform.origin), sep_ok])

	# 45° 对角：外接圆模型会误判为重叠，OBB 才能正确贴合
	var ps2 := [
		PropLayoutTool.solve(_build(), 1, Vector2(0, 0), 0.0, Callable(), {}),
		PropLayoutTool.solve(_build(), 2, Vector2(7, 7), PI * 0.25, Callable(), {}),
	]
	var pre2 := PropLayoutTool.has_overlap(ps2, 1.0)
	PropLayoutTool.relax(ps2, 32, 1.0)
	var post2 := PropLayoutTool.has_overlap(ps2, 1.0)
	# 两个同尺寸 45° 相对的建筑，外接圆半径 5m，中心距 9.9m → 圆模型判不重叠，OBB 判重叠
	print("[布局] 45° 对角: 圆心距=%.2f 圆半径=%.2f 松弛前=%s 松弛后=%s" % [
		ps2[0].xform.origin.distance_to(ps2[1].xform.origin), 5.0, pre2, post2])
	all_ok = all_ok and not post2

	# 无重叠集合不应被推开（幂等性：不能引入新冲突）
	var far := [
		PropLayoutTool.solve(_build(), 1, Vector2(0, 0), 0.0, Callable(), {}),
		PropLayoutTool.solve(_build(), 2, Vector2(50, 0), 0.0, Callable(), {}),
	]
	var p0: Vector3 = far[0].xform.origin
	PropLayoutTool.relax(far, 8, 0.92)
	var idle_ok: bool = far[0].xform.origin.distance_to(p0) < 1e-4 and not PropLayoutTool.has_overlap(far, 0.92)
	all_ok = all_ok and idle_ok
	print("[布局] 已分离集合保持不动: ok=%s" % idle_ok)

	# 批量摆放
	var items := [
		{&"build": _build(), &"seed": 1, &"at": Vector2(0, 0), &"yaw": 0.0},
		{&"build": _build(), &"seed": 2, &"at": Vector2(1, 0), &"yaw": 0.0},
		{&"build": _build(), &"seed": 3, &"at": Vector2(2, 0), &"yaw": 0.0},
		{&"build": _build(), &"seed": 4, &"at": Vector2(3, 0), &"yaw": 0.0,
			&"opts": {&"blocked": func(_x: float, _z: float) -> bool: return true}},
	]
	var placed := PropLayoutTool.place_all(items, g, 1.0)
	var batch_ok := placed.size() == 3 and not PropLayoutTool.has_overlap(placed, 1.0)
	all_ok = all_ok and batch_ok
	print("[布局] 批量摆放: 入 4 出 %d(拒 1) 无重叠=%s ok=%s" % [
		placed.size(), not PropLayoutTool.has_overlap(placed, 1.0), batch_ok])

	# —— 4. 存档语义：只存 seed + 位置 + 朝向即可重建，网格不入档 ——
	var src := PropLayoutTool.solve(b, 4242, Vector2(10, 0), 0.37, g, {&"snap": PropLayoutTool.Snap.MIN})
	var save_rec := {
		&"seed": src.seed_value,
		&"pos": [src.xform.origin.x, src.xform.origin.y, src.xform.origin.z],
		&"yaw": src.yaw,
	}
	var restored := PropLayoutTool.solve(_build(), int(save_rec[&"seed"]),
		Vector2(save_rec[&"pos"][0], save_rec[&"pos"][2]), float(save_rec[&"yaw"]), g,
		{&"snap": PropLayoutTool.Snap.MIN})
	var rec_ok := restored.xform.origin.is_equal_approx(src.xform.origin) \
		and absf(restored.yaw - src.yaw) < 1e-6
	all_ok = all_ok and rec_ok
	print("[布局] seed+pos+yaw 重建原布局: ok=%s (档内无网格, %d 字段)" % [rec_ok, save_rec.size()])

	print("== SDF 布局测试 %s ==" % ("全部通过" if all_ok else "存在失败"))
	return all_ok
