class_name PCGNativeTest
extends RefCounted

## FrameworkNative / 原生共享库 自动化自检
##
## 验证 addons/DEVFramework/Native/dev.gdextension 注册的全部原生类:
##   ECSCore / PCGErode / PCGWFC / PCGWFC3D / PCGWFCAnimator / PCGLSystem / PCGCave3D
## 检查: 加载 / 方法集 / 功能正确性 / 同 seed 可复现 / 缺库报错路径。

static func run() -> bool:
	var all_ok := true

	# ---- 1. 全部原生类经 FrameworkNative 加载 ----
	var class_checks := [
		func() -> bool:
			var m := [&"create_entity", &"add_component"] as Array[StringName]
			return FrameworkNative.get_native(&"ECSCore", m) != null,
		func() -> bool:
			var m := [&"erode", &"thermal"] as Array[StringName]
			return FrameworkNative.get_native(&"PCGErode", m) != null,
		func() -> bool:
			var m := [&"generate", &"get_last_progress"] as Array[StringName]
			return FrameworkNative.get_native(&"PCGWFC", m) != null,
		func() -> bool:
			var m := [&"generate", &"get_last_progress"] as Array[StringName]
			return FrameworkNative.get_native(&"PCGWFC3D", m) != null,
		func() -> bool:
			var m := [&"setup", &"step", &"get_wave"] as Array[StringName]
			return FrameworkNative.get_native(&"PCGWFCAnimator", m) != null,
		func() -> bool:
			var m := [&"generate"] as Array[StringName]
			return FrameworkNative.get_native(&"PCGLSystem", m) != null,
		func() -> bool:
			var m := [&"generate"] as Array[StringName]
			return FrameworkNative.get_native(&"PCGCave3D", m) != null,
	]
	var class_names := ["ECSCore", "PCGErode", "PCGWFC", "PCGWFC3D", "PCGWFCAnimator", "PCGLSystem", "PCGCave3D"]
	for i in class_checks.size():
		var ok: bool = class_checks[i].call()
		if not ok:
			all_ok = false
		print("[Native] %s 加载+方法校验: %s" % [class_names[i], ok])

	# ---- 2. PCGErode: 水力侵蚀 ----
	var erode: Object = FrameworkNative.get_native(&"PCGErode", [&"erode"])
	var h := PackedFloat32Array()
	h.resize(48 * 48)
	for y in 48:
		for x in 48:
			h[y * 48 + x] = 0.5 + 0.2 * sin(x * 0.3) * cos(y * 0.2)
	var e1: PackedFloat32Array = erode.call(&"erode", h, 48, 48, 1000, 0.1, 0.2, 2, 0.005, 0.02, 42, 0.0, 1.0)
	var e2: PackedFloat32Array = erode.call(&"erode", h, 48, 48, 1000, 0.1, 0.2, 2, 0.005, 0.02, 42, 0.0, 1.0)
	var erode_ok := e1.size() == 48 * 48 and e1 == e2
	if not erode_ok:
		all_ok = false
	print("[Native] PCGErode 侵蚀大小+可复现: %s" % erode_ok)

	# ---- 3. PCGErode: 热侵蚀 ----
	var t1: PackedFloat32Array = erode.call(&"thermal", h, 48, 48, 10, 0.05)
	var t2: PackedFloat32Array = erode.call(&"thermal", h, 48, 48, 10, 0.05)
	var thermal_ok := t1.size() == 48 * 48 and t1 == t2
	if not thermal_ok:
		all_ok = false
	print("[Native] PCGErode 热侵蚀大小+可复现: %s" % thermal_ok)

	# ---- 4. PCGWFC: 2D WFC ----
	var wfc_def: GridGenDef = load("res://Assets/Def/PCG/Grid_WFC.tres")
	var g1: GeneratedGrid = PCGTool.generate_grid(wfc_def, PCGTool.make_rng(42))
	var g2: GeneratedGrid = PCGTool.generate_grid(wfc_def, PCGTool.make_rng(42))
	var wfc_ok := g1.cells == g2.cells and g1.cells.size() == wfc_def.width * wfc_def.height
	if not wfc_ok:
		all_ok = false
	print("[Native] PCGWFC 2D WFC 可复现+尺寸: %s" % wfc_ok)

	# ---- 5. PCGWFC3D: 3D WFC ----
	var wfc3_def: Grid3DGenDef = load("res://Assets/Def/PCG/Grid3D_WFC.tres")
	var w3a: GeneratedGrid3D = PCGTool.generate_grid_3d(wfc3_def, PCGTool.make_rng(5))
	var w3b: GeneratedGrid3D = PCGTool.generate_grid_3d(wfc3_def, PCGTool.make_rng(5))
	var wfc3_ok := w3a.cells == w3b.cells
	if not wfc3_ok:
		all_ok = false
	print("[Native] PCGWFC3D 3D WFC 可复现: %s" % wfc3_ok)

	# ---- 6. PCGWFCAnimator: 动画器逐步推进 ----
	var anim := WFCAnimator.new()
	anim.setup(wfc_def, PCGTool.make_rng(42))
	var guard := 0
	while not anim.step():
		guard += 1
		if guard > 5000:
			break
	var anim_ok := anim.done and not anim.failed and anim.step_count > 0
	if not anim_ok:
		all_ok = false
	print("[Native] PCGWFCAnimator 推进完成: %s (steps=%d)" % [anim_ok, anim.step_count])

	# ---- 7. PCGLSystem: L-System ----
	var ls := LSystemDef.new()
	ls.axiom = "X"
	ls.rules = {"X": "F+[[X]-X]-F[-FX]+X", "F": "FF"}
	ls.iterations = 4
	ls.max_segments = 50000
	var ls1 := PCGTool.generate_lsystem(ls, PCGTool.make_rng(42))
	var ls2 := PCGTool.generate_lsystem(ls, PCGTool.make_rng(42))
	var ls_ok := ls1.size() > 0 and ls1 == ls2
	if not ls_ok:
		all_ok = false
	print("[Native] PCGLSystem 线段数+可复现: %s (segs=%d)" % [ls_ok, ls1.size() / 2])

	# ---- 8. PCGCave3D: 3D 洞穴 ----
	var cave_def: Grid3DGenDef = load("res://Assets/Def/PCG/Grid3D_Cave.tres")
	var c1: GeneratedGrid3D = PCGTool.generate_grid_3d(cave_def, PCGTool.make_rng(42))
	var c2: GeneratedGrid3D = PCGTool.generate_grid_3d(cave_def, PCGTool.make_rng(42))
	var cave_ok := c1.cells == c2.cells and c1.components(cave_def.empty_value).size() == 1
	if not cave_ok:
		all_ok = false
	print("[Native] PCGCave3D 可复现+空腔连通: %s" % cave_ok)

	# ---- 9. 缺库报错路径 ----
	var nonexist_loaded := FrameworkNative.is_extension_loaded(&"NoSuchClass")
	var nonexist_inst := FrameworkNative.get_native(&"NoSuchClass", [])
	var missing_ok := not nonexist_loaded and nonexist_inst == null
	if not missing_ok:
		all_ok = false
	print("[Native] 缺库报错路径(不存在的类): %s" % missing_ok)

	print("== 原生库测试 %s ==" % ("全部通过" if all_ok else "存在失败"))
	return all_ok