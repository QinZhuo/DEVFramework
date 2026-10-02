class_name PCGSdfGenTest
extends RefCounted

## SDF 单体生成（PropGen 层）回归测试
##
## 覆盖三条契约：
##   1. 烘焙闭环：PropGenDef → SdfField → SdfMesh，产出非空 PropBuild
##   2. 确定性：同 seed 两次烘焙逐顶点一致；异 seed 结果不同
##   3. 分层红线：PropBuild 是**纯局部空间**，不含任何世界坐标
##      —— 这是"独立物体生成器"能独立存在的前提，一旦被破坏，
##         存档就必须存网格而非 seed，PropLayoutTool 的对偶关系也随之失效。

## —— 测试夹具：具体生成器（框架外的最小实现）——

## 确定性盒体：不取随机，任何 seed 都应得到同一形状
class BoxProp extends PropGen:
	var half := Vector3(3, 1.75, 4)

	func local_bounds() -> AABB:
		return AABB(
			Vector3(-half.x, 0.0, -half.z),
			Vector3(half.x * 2.0, half.y, half.z * 2.0))

	func build(_field: SdfField) -> void:
		fill_shape(_shape)

	func _shape(p: Vector3) -> float:
		return SdfTool.sd_box(p - Vector3(0, half.y, 0), half)

	func meta() -> Dictionary:
		return {&"tag": "test_box", &"surface_snap": true, &"face_dir": Vector3i(0, 0, 1)}


## 随机盒体：尺寸由 rng 决定，用于验证 seed 真的流进几何
class RandomProp extends PropGen:
	func local_bounds() -> AABB:
		return AABB(Vector3(-2, 0, -2), Vector3(4, 4, 4))

	func build(_field: SdfField) -> void:
		var h := rng.randf_range(0.7, 1.9)
		fill_shape(func(p: Vector3) -> float:
			return SdfTool.sd_box(p - Vector3(0, 2, 0), Vector3(h, 2, h)))


static func _def(algo := MeshExtractor.Algo.SURFACE_NETS) -> PropGenDef:
	var d := PropGenDef.new()
	d.voxel_size = 0.2
	d.margin = 0.5
	d.algo = algo
	return d


static func run() -> bool:
	var all_ok := true
	var d := _def()

	# —— 1. 烘焙闭环 ——
	var b := PropGenTool.bake(BoxProp.new(), d, 1234)
	var not_empty := b != null and not b.is_empty() and b.vertex_count() > 0 and b.triangle_count() > 0
	all_ok = (all_ok and not_empty) or _fail("烘焙产出空网格")
	print("[生成] 盒体烘焙: v=%d tri=%d ok=%s" % [b.vertex_count(), b.triangle_count(), not_empty])

	# 尺寸应贴合 local_bounds（6 × 3.5 × 8），容差为 2 个体素
	var tol := d.voxel_size * 2.0
	var want := Vector3(6, 3.5, 8)
	var got := b.bounds.size
	var size_ok := absf(got.x - want.x) <= tol and absf(got.y - want.y) <= tol and absf(got.z - want.z) <= tol
	all_ok = all_ok and size_ok
	print("[生成] 尺寸贴合 local_bounds: %s (实际 %s)" % [size_ok, got])

	# —— 2. 分层红线：纯局部空间 ——
	# y 从 0 起算：包围盒最低点必须在 0 附近。若生成器偷偷掺了世界高度（例如贴到 terrain.y），
	# 这里会立刻暴露 —— 而那正是"世界数据吞并单体内容"的开始。
	var local_y_ok := absf(b.bounds.position.y) <= tol
	var fp_ok := b.footprint.is_equal_approx(Vector2(6, 8))
	all_ok = all_ok and local_y_ok and fp_ok
	print("[生成] 局部空间不变量: y0≈0 %s (%.3f)  footprint %s" % [local_y_ok, b.bounds.position.y, fp_ok])

	# meta 只透传、不解释
	var meta_ok: bool = b.meta.get(&"tag", "") == "test_box" and bool(b.meta.get(&"surface_snap", false))
	all_ok = all_ok and meta_ok
	print("[生成] meta 透传: %s" % meta_ok)

	# —— 3. 确定性 ——
	var b2 := PropGenTool.bake(BoxProp.new(), d, 1234)
	var det := b.mesh.vertices == b2.mesh.vertices and b.mesh.indices == b2.mesh.indices
	all_ok = all_ok and det
	print("[生成] 同 seed 逐顶点复现: %s" % det)

	# 同实例 rebake 也必须复现（rng 重新派生，不残留上次状态）
	var g := BoxProp.new()
	var r1 := g.rebake(1234)
	var r2 := g.rebake(1234)
	var rebake_ok := r1.mesh.vertices == r2.mesh.vertices
	all_ok = all_ok and rebake_ok
	print("[生成] 同实例 rebake 复现: %s" % rebake_ok)

	# 异 seed 必须产生不同几何（否则 seed 没流进 build，等于生成器写死了）
	var ra := PropGenTool.bake(RandomProp.new(), d, 100)
	var rb := PropGenTool.bake(RandomProp.new(), d, 200)
	var diff := ra.bounds.size.x != rb.bounds.size.x
	all_ok = all_ok and diff
	print("[生成] 异 seed 产生不同形状: %s (%.3f vs %.3f)" % [diff, ra.bounds.size.x, rb.bounds.size.x])

	# 换地图 seed 不应改变单体形状：mix_seed 把「哪一栋楼」与「整张地图」解耦
	var m := PropGenTool.mix_seed(999, 3, 7)
	var m2 := PropGenTool.mix_seed(1000, 3, 7)
	var m3 := PropGenTool.mix_seed(999, 4, 7)
	print("[生成] mix_seed 解耦: %s (换 world_seed:%s 换 kind:%s)" % [
		m != m2, m != m2, m != m3])

	# —— 4. 另一种算法 ——
	var dc := PropGenTool.bake(BoxProp.new(), _def(MeshExtractor.Algo.DUAL_CONTOURING), 1234)
	var dc_ok := dc != null and not dc.is_empty()
	all_ok = all_ok and dc_ok
	print("[生成] DualContouring 烘焙: v=%d ok=%s" % [dc.vertex_count(), dc_ok])

	# —— 5. 网格 → 体素（射线奇偶）——
	# 回归重点是**共享棱双计数**：射线正好打在两个三角形的公共边上时两个三角形都报命中
	# → 计 2 次 → 偶数 → 整条体素列被判成外部。2×2 盒子的顶面只有 2 个三角形，
	# 其对角棱正下方 32 条列会全空，表现为 32³ 只填了 31744 / 32768。
	# 所以这里断言"**全满**"而不是断言数量近似 —— 近似断言会让这个 bug 溜过去。
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE * 2.0
	var vox := VoxelExtractor.extract_from_mesh(bm, 32, {})
	var full_ok := vox.count_solid() == vox.voxel_count()
	all_ok = all_ok and full_ok
	print("[体素] 2m 盒子填满 %d³: %s (%d/%d)" % [
		vox.size.x, full_ok, vox.count_solid(), vox.voxel_count()])

	# 确定性：同一网格两次抽取必须逐字节一致（否则存档/缓存/产物比对全部失效）
	var vox2 := VoxelExtractor.extract_from_mesh(bm, 32, {})
	var vox_det := vox.data == vox2.data
	all_ok = all_ok and vox_det
	print("[体素] 逐字节复现: %s" % vox_det)

	# 亏格 1：环面中央孔必须保持空。奇偶在"射线两次进出"下仍应正确，
	# 且孔洞不能被误判成实心（只看总数量是发现不了孔洞问题的）。
	var tm := TorusMesh.new()
	tm.inner_radius = 0.4
	tm.outer_radius = 1.0
	tm.rings = 24
	tm.ring_segments = 16
	var tv := VoxelExtractor.extract_from_mesh(tm, 32, {})
	var hole_n := 0
	var hole_bad := 0
	for y in tv.size.y:
		for z in tv.size.z:
			for x in tv.size.x:
				var p: Vector3 = tv.origin + Vector3(x + 0.5, y + 0.5, z + 0.5) * tv.voxel
				if sqrt(p.x * p.x + p.z * p.z) < 0.3:
					hole_n += 1
					if tv.get_voxel(x, y, z) != SdfVoxel.EMPTY:
						hole_bad += 1
	var hole_ok := hole_n > 0 and hole_bad == 0
	all_ok = all_ok and hole_ok
	print("[体素] 环面孔洞保持空（检查 %d 格，误判 %d）: %s" % [hole_n, hole_bad, hole_ok])

	# 闭合体检：两只三角形拼成的四边形有 4 条边界边 —— 共享的那条对棱正是把 32 条列
	# 判空的接缝。这条断言守住"开口网格静默产出垃圾体素"这个坑。
	var quad := PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1),
		Vector3(0, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)])
	var quad_open := VoxelExtractor.open_edge_count(quad)
	var quad_ok := quad_open == 4
	all_ok = all_ok and quad_ok
	print("[体素] 四边形边界边 = %d（应为 4）: %s" % [quad_open, quad_ok])

	print("== SDF 生成测试 %s ==" % ("全部通过" if all_ok else "存在失败"))
	return all_ok


static func _fail(what: String) -> bool:
	push_error("[PCGSdfGenTest] " + what)
	return false
