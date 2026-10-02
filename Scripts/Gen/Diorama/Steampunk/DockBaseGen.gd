@tool
class_name DockBaseGen
extends PropGen
## 用例五底座 —— 黄铜与木质的矩形展示台，边缘一圈铆钉、四角嵌齿轮浮雕
##
## ## 三层剖面就是"展示底座"的全部表达
## 木甲板（上） / 黄铜框（中，外伸 0.12） / 铁基座（下，内收 0.2）。
## 三层各有各的色，于是在侧面拉开三条水平色带 —— 这正是"摆在桌上的展示台"
## 该有的读法，比任何浮雕都先被看见。
##
## ## 铆钉与齿轮为什么是"离散的一圈"而不是连续纹样
## 体素/低模语境下没有"贴图"这回事，装饰必须**真的占体积**。
## 铆钉做成 8 棱小柱凸出框面 0.05 米，齿轮做成 8 齿的扁棱柱凸出甲板 0.05 米 ——
## 凸出这一点点就够了：它们各自在光照下投下一格阴影，而那道阴影才是"浮雕"。
## 做成平面凹刻则完全看不见（没有 AO、没有法线细节）。
##
## ## 数量是数过的
## 铆钉 20 个、齿轮 4 个 ×8 齿 = 52 个额外 SDF/格。全场约 1.3 万格，
## 每格要跑 50 多次距离函数 —— 这是烘焙耗时的主要来源，
## 所以这里的数字是"看得见"的下限，不是越多越好。

## 14×10。定这么大是因为**飞艇有 5.5 米长**：它沿切线横在岛前方时，
## 两个端点会甩到中心 ±2.8 米处，加上锅炉、码头、两组道具，
## 12×9 的台面会让 relax 把它们一路推到台沿（与用例二同一个坑）。
## 台面是矩形，逐轴的越界判定在这里**是有效的**，所以放大它是安全的：
## 越界的会被直接剔除，不会像六边形那样"看着没越界其实悬空"。
const HALF_X := 7.0     ## 甲板半长（X）
const HALF_Z := 5.0     ## 甲板半宽（Z）
const DECK_T := 0.22    ## 木甲板厚：y ∈ [-0.22, 0]
const FRAME_T := 0.23   ## 黄铜框：y ∈ [-0.45, -0.22]，四周外伸 0.12
const BASE_T := 0.27    ## 铁基座：y ∈ [-0.72, -0.45]，四周内收 0.20
const RIVET_N := 5      ## 每条长边 / 短边各几颗铆钉
const GEAR_N := 8       ## 齿轮齿数

## 四角齿轮的中心（甲板内侧，避免被 relax 判越界时顶到边）
func _gear_centers() -> Array:
	var gx := HALF_X - 0.75
	var gz := HALF_Z - 0.75
	return [
		Vector3(-gx, 0.0, -gz), Vector3(gx, 0.0, -gz),
		Vector3(-gx, 0.0, gz), Vector3(gx, 0.0, gz),
	]

## 一圈铆钉的中心（贴在黄铜框外侧面上，y = -0.33）
func _rivets() -> Array:
	var out := []
	var y := -0.335
	var fx := HALF_X + 0.12
	var fz := HALF_Z + 0.12
	for i in RIVET_N:
		var t := (float(i) + 0.5) / float(RIVET_N)
		var x := -HALF_X + 2.0 * HALF_X * t
		out.append(Vector3(x, y, fz))
		out.append(Vector3(x, y, -fz))
	for i in 3:
		var t := (float(i) + 0.5) / 3.0
		var z := -HALF_Z + 2.0 * HALF_Z * t
		out.append(Vector3(fx, y, z))
		out.append(Vector3(-fx, y, z))
	return out

func local_bounds() -> AABB:
	return AABB(Vector3(-HALF_X - 0.25, -DECK_T - FRAME_T - BASE_T, -HALF_Z - 0.25),
		Vector3((HALF_X + 0.25) * 2.0, DECK_T + FRAME_T + BASE_T + 0.10,
			(HALF_Z + 0.25) * 2.0))

func build(_field: SdfField) -> void:
	var gears := _gear_centers()
	var rivets := _rivets()
	fill_shape(func(p: Vector3) -> float:
		var d := SdfTool.sd_box(p - Vector3(0.0, -DECK_T * 0.5, 0.0),
			Vector3(HALF_X, DECK_T * 0.5, HALF_Z))
		## 黄铜框：外伸 0.12，把甲板"托"在里面
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, -DECK_T - FRAME_T * 0.5, 0.0),
			Vector3(HALF_X + 0.12, FRAME_T * 0.5, HALF_Z + 0.12)))
		## 铁基座：内收 0.20，收出一道踢脚
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, -DECK_T - FRAME_T - BASE_T * 0.5, 0.0),
			Vector3(HALF_X - 0.20, BASE_T * 0.5, HALF_Z - 0.20)))
		## 铆钉：凸出框面 0.05
		for r in rivets:
			d = SdfTool.op_union(d, SdfTool.sd_prism(p - r, 0.075, 0.075, 8))
		## 四角齿轮：8 齿扁棱柱，凸出甲板 0.05
		for g in gears:
			d = SdfTool.op_union(d, SdfTool.sd_prism(
				p - Vector3(g.x, 0.04, g.z), 0.42, 0.04, 8))
			for i in GEAR_N:
				var a := TAU * float(i) / float(GEAR_N)
				d = SdfTool.op_union(d, SdfTool.sd_box(
					p - Vector3(g.x + cos(a) * 0.44, 0.04, g.z + sin(a) * 0.44),
					Vector3(0.10, 0.04, 0.10)))
		return d)

func voxel_regions() -> Array:
	var b := local_bounds()
	var out := []
	## ① 齿轮（暗铜）：凸在甲板之上，先判
	for g in _gear_centers():
		out.append(SteamSkin.box(Vector3(g.x, 0.04, g.z),
			Vector3(1.10, 0.10, 1.10), SteamSkin.BRASS_DK))
	## ② 铆钉（暗铜）：贴在框侧面
	for r in _rivets():
		out.append(SteamSkin.box(r, Vector3(0.20, 0.20, 0.20), SteamSkin.BRASS_DK))
	## ③ 铁基座
	out.append(SteamSkin.band_y(b.position.y, -DECK_T - FRAME_T, HALF_X, SteamSkin.IRON))
	## ④ 黄铜框
	out.append(SteamSkin.band_y(-DECK_T - FRAME_T, -DECK_T, HALF_X, SteamSkin.BRASS))
	## ⑤ 兜底：木甲板
	out.append(SteamSkin.all(b, SteamSkin.WOOD_LT))
	return out

func meta() -> Dictionary:
	return {
		&"tag": "dock_base",
		&"surface_snap": false,
		&"wants_ground": false,
	}
