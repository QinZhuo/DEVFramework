class_name PCGSdfSlotTest
extends RefCounted

## SDF 材质槽位（slots）回归测试
##
## ============================ 为什么单独补这一份 ============================
## 槽位是"不用贴图也能分件上色"的**唯一数据通道**：
## 网格走顶点色、体素走调色板索引，两者都读它。它一旦语义漂移，
## 症状是"换了个配色资源，整片屋顶变成柱子的颜色" —— 而这种错在
## 烘焙日志里**没有任何报错**，只能靠这里挡住。
##
## 覆盖 [method SdfField.assign_slot_solid] 的四条语义 + 窄带前提：
##   1. 只填未指定（先来先得）—— "主体 → 细节"分层上色的依据
##   2. overwrite 覆盖
##   3. 越界夹紧到 0~253（254/255 是哨兵，绝不能被写成普通槽位）
##   4. band_only：窄带外的实心体素**不写**，这是性能前提而非偷懒
##
## 全程不提网格，只操作场 —— 因此本测试是毫秒级的，可以放心每次都跑。

## 实心体素必须在窄带内（|d| <= band）才会被 assign_slot_solid 扫到：
## 等值面只可能出现在窄带上，窄带外的实心量永远不会被提取器读到。
const BAND := 0.75
const FILL_IN_BAND := -0.5      ## 窄带内的实心
const FILL_OUT_BAND := -2.0     ## 窄带外的实心（深埋内部）
const SOLID_COUNT := 512        ## 8³

static func _field(fill: float) -> SdfField:
	var f := SdfField.create(16, 0.25, Vector3.ZERO, BAND)
	for x in range(4, 12):
		for y in range(4, 12):
			for z in range(4, 12):
				f.set_voxel(x, y, z, fill)
	return f

static func _slot(s: int, overwrite: bool) -> ModelSlotNode:
	var n := ModelSlotNode.new()
	n.slot = s
	n.overwrite = overwrite
	return n

static func run() -> bool:
	var all_ok := true

	# —— 1. 只填未指定 ——
	var f := _field(FILL_IN_BAND)
	var written := f.assign_slot_solid(7)
	all_ok = _ck(all_ok, written == SOLID_COUNT, "首次赋值应写入全部 %d 个实心体素，实得 %d" % [SOLID_COUNT, written])
	var h := f.slot_histogram()
	all_ok = _ck(all_ok, h.get(7, 0) == SOLID_COUNT, "槽位 7 的体素数应为 %d，实得 %d" % [SOLID_COUNT, h.get(7, 0)])

	# —— 2. 先来先得：不覆盖已有 ——
	var w2 := f.assign_slot_solid(9)
	all_ok = _ck(all_ok, w2 == 0, "overwrite=false 时二次赋槽位应写入 0 个，实得 %d" % w2)
	all_ok = _ck(all_ok, f.slot_histogram().get(7, 0) == SOLID_COUNT, "overwrite=false 不应冲掉已有的槽位 7")

	# —— 3. 覆盖 ——
	var w3 := f.assign_slot_solid(2, true)
	all_ok = _ck(all_ok, w3 == SOLID_COUNT, "overwrite=true 应覆盖全部 %d 个，实得 %d" % [SOLID_COUNT, w3])
	all_ok = _ck(all_ok, f.slot_histogram().get(2, 0) == SOLID_COUNT, "覆盖后槽位 2 应持有全部实心体素")
	all_ok = _ck(all_ok, f.slot_histogram().get(7, 0) == 0, "覆盖后槽位 7 应清空")

	# —— 4. 越界夹紧（经 ModelSlotNode，走的是节点那条路径）——
	var f2 := _field(FILL_IN_BAND)
	_slot(999, true).post(f2)
	all_ok = _ck(all_ok, f2.slot_histogram().get(253, 0) == SOLID_COUNT,
		"槽位 999 应被夹紧到 253（254/255 是哨兵），实得 %s" % str(f2.slot_histogram()))
	var f3 := _field(FILL_IN_BAND)
	_slot(-5, true).post(f3)
	all_ok = _ck(all_ok, f3.slot_histogram().get(0, 0) == SOLID_COUNT, "负槽位应被夹紧到 0")

	# —— 5. 窄带前提：深埋内部的实心不写 ——
	var f4 := _field(FILL_OUT_BAND)
	var w5 := f4.assign_slot_solid(5)
	all_ok = _ck(all_ok, w5 == 0, "band_only=true 时窄带外的实心体素应一个都不写，实得 %d" % w5)
	var w6 := f4.assign_slot_solid(5, false, false)
	all_ok = _ck(all_ok, w6 == SOLID_COUNT, "band_only=false 时应扫全盒，写入 %d 个，实得 %d" % [SOLID_COUNT, w6])

	# —— 6. 未分配槽位时读取应给出 SLOT_NONE，而不是崩溃或脏值 ——
	var f5 := _field(FILL_IN_BAND)
	all_ok = _ck(all_ok, not f5.has_slots(), "未赋槽位前不应已分配槽位通道")
	all_ok = _ck(all_ok, f5.slot_at_world(Vector3i(6, 6, 6)) == SdfField.SLOT_NONE, "未分配时读取应返回 SLOT_NONE")

	print("[槽位] 六项语义检查完毕")
	return all_ok

static func _ck(ok: bool, cond: bool, msg: String) -> bool:
	if not cond:
		print("[槽位] 失败: " + msg)
	elif ok:
		print("[槽位] 通过: " + msg)
	return ok and cond
