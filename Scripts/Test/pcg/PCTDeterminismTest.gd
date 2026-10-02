class_name PCTDeterminismTest
extends RefCounted

## PCG 确定性测试 — 同 seed 必复现，不同 seed 不同
##
## PCG 只做 3D，所以这里没有 2D 网格分支。断言分四类：
##   1. 四种 3D 栅格算法同 seed 逐格一致
##   2. WFC 固定格（点 / 盒）在同 seed 下也一致
##   3. 分块世界同 seed + 同 chunk 坐标一致（跨块边界的拼接也必须一致）
##   4. 生成管线同 seed 下各输出产物一致
## 另有一条反向断言：不同 seed 必须产出不同结果 —— 只测"同 seed 一致"的话，
## 一个把所有输入都当常量的实现也能全绿。


static func run() -> bool:
	var all_ok := true

	var d3s := {
		"Surface": load("res://Assets/Def/PCG/Grid3D_Surface.tres") as Grid3DGenDef,
		"Cave3D": load("res://Assets/Def/PCG/Grid3D_Cave.tres") as Grid3DGenDef,
		"WFC3D": load("res://Assets/Def/PCG/Grid3D_WFC.tres") as Grid3DGenDef,
		"NoiseCave3D": load("res://Assets/Def/PCG/Grid3D_NoiseCave.tres") as Grid3DGenDef,
	}

	# —— 1. 各3D 算法：同 seed 两次生成必须完全一致 ——
	for name in d3s:
		var d: Grid3DGenDef = d3s[name]
		var a := PCGTool.generate_grid_3d(d, PCGTool.make_rng(7))
		var b := PCGTool.generate_grid_3d(d, PCGTool.make_rng(7))
		var ok := a.cells == b.cells and a.count(d.empty_value) == b.count(d.empty_value)
		if not ok:
			all_ok = false
		print("[确定性] 3D %s 同 seed 复现: %s" % [name, ok])

	# —— 2. 3D WFC 固定格：点固定 + 盒固定，同 seed 复现 ——
	var wfc3_def: Grid3DGenDef = d3s["WFC3D"]
	var f3 := {Vector3i(2, 2, 2): 0, Vector3i(3, 3, 3): 1, AABB(Vector3(10, 10, 10), Vector3(2, 1, 2)): 0}
	var f3a := PCGTool.generate_grid_3d(wfc3_def, PCGTool.make_rng(5), f3)
	var f3b := PCGTool.generate_grid_3d(wfc3_def, PCGTool.make_rng(5), f3)
	var wfc3_fix_ok := f3a.cells == f3b.cells
	# 固定格必须真的被钉住，否则"复现"只是因为 WFC 恰好长成了这样
	var pinned_ok := f3a.get_cell(2, 2, 2) == 0 and f3a.get_cell(3, 3, 3) == 1
	if not wfc3_fix_ok or not pinned_ok:
		all_ok = false
	print("[确定性] 3D WFC 固定格复现: %s ／ 固定格被钉住: %s" % [wfc3_fix_ok, pinned_ok])

	# —— 3. 分块世界：同 seed + 同 chunk 坐标复现 ——
	var surface: Grid3DGenDef = d3s["Surface"]
	var world_a := ChunkedWorld3D.new()
	world_a.seed_base = 42
	world_a.grid3d_def = surface
	world_a.chunk_size = 8
	var world_b := ChunkedWorld3D.new()
	world_b.seed_base = 42
	world_b.grid3d_def = surface
	world_b.chunk_size = 8
	var world_ok := true
	for k in [Vector3i(0, 0, 0), Vector3i(1, 0, -1), Vector3i(-2, 1, 3)]:
		var ga: GeneratedGrid3D = world_a.get_chunk(k.x, k.y, k.z)
		var gb: GeneratedGrid3D = world_b.get_chunk(k.x, k.y, k.z)
		if ga.cells != gb.cells:
			world_ok = false
	if not world_ok:
		all_ok = false
	print("[确定性] 3D 分块世界同 seed 复现: %s" % world_ok)

	# —— 4. 管线：同 seed 各输出产物一致 ——
	var pipe := load("res://Assets/Def/PCG/Pipeline_World.tres") as PCGDef
	var oa := PCGTool.generate(pipe, 777)
	var ob := PCGTool.generate(pipe, 777)
	var pipe_ok := oa.size() == ob.size()
	for k in oa:
		var va = oa[k]
		var vb = ob[k]
		if va is GeneratedGrid3D and vb is GeneratedGrid3D:
			if (va as GeneratedGrid3D).cells != (vb as GeneratedGrid3D).cells:
				pipe_ok = false
		elif va is PackedVector3Array and vb is PackedVector3Array:
			if (va as PackedVector3Array) != (vb as PackedVector3Array):
				pipe_ok = false
	if not pipe_ok:
		all_ok = false
	print("[确定性] 管线同 seed 复现: %s（%d 个输出）" % [pipe_ok, oa.size()])

	# —— 5. 反向：不同 seed 必须不同（否则上面的全绿可能来自"忽略了 seed"） ——
	var cave: Grid3DGenDef = d3s["Cave3D"]
	var c7 := PCGTool.generate_grid_3d(cave, PCGTool.make_rng(42))
	var c8 := PCGTool.generate_grid_3d(cave, PCGTool.make_rng(43))
	var diff_ok := c7.cells != c8.cells
	if not diff_ok:
		all_ok = false
	print("[确定性] 不同 seed 不同: %s" % diff_ok)

	# —— 6. 散布：同 seed 点集一致 ——
	var place := load("res://Assets/Def/PCG/Place_3D_Nature.tres") as PlacementDef3D
	var pa := PCGTool.place_3d(place, PCGTool.make_rng(3))
	var pb := PCGTool.place_3d(place, PCGTool.make_rng(3))
	var pc := PCGTool.place_3d(place, PCGTool.make_rng(4))
	var place_ok := pa == pb and pa != pc and not pa.is_empty()
	if not place_ok:
		all_ok = false
	print("[确定性] 3D 散布同 seed 复现/异 seed 不同: %s（%d 点）" % [place_ok, pa.size()])

	print("== 确定性测试 %s ==" % ("全部通过" if all_ok else "存在失败"))
	return all_ok