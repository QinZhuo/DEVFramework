@tool
class_name PlankBridgeGen
extends PropGen
## 用例二环境 —— 木桥跨过小溪（水、桥、堤岸作为**一件**单体）
##
## ## 为什么溪与桥必须同一件
## 分成两件的话，摆放层会把它们当作两个各自需要避让的单体：
## 桥面与溪岸会互相推开，最后桥横在草地上、溪孤零零一条 ——
## "跨过"这个关系在落位阶段就已经丢了，而且**不报错**。
## 关系是几何的一部分，所以放在同一个 [method PropGen.build] 里。
##
## 局部坐标约定：**溪沿 X 流，桥沿 Z 跨**。于是本件在场景里旋转 yaw
## 就能让溪以任意角度穿过广场，而桥永远垂直于它。

## 整件 3.4×2.3，是这座岛上最大的单件道具 —— 再大就会在切向上顶到岛边
## （沿切线摆时最远的角会甩到半径 4.5 外，越出内切圆 4.68 的余量）。
const STREAM_HALF_Z := 0.55  ## 溪的半宽（沿 Z）
const STREAM_HALF_X := 1.55  ## 溪的半长（沿 X）
const WATER_TOP := 0.04      ## 水面 y（略高于 0，压住草地不被 z-fight）
const DECK_Y := 0.30         ## 桥面顶面 y
const DECK_HALF_X := 0.52    ## 桥面半宽（沿 X）
const DECK_HALF_Z := 1.05    ## 桥面半长（沿 Z，> 溪半宽 ⇒ 真的跨过去）
const PLANKS := 6            ## 桥面木板数（沿 Z 排布 ⇒ 木纹方向与过桥方向垂直）
const RAIL_X := 0.44         ## 栏杆柱的 x 偏移

func _water(p: Vector3) -> float:
	## 水面：一薄片，两侧用堤岸石压边（堤岸是实心石，不是水）
	return SdfTool.sd_box(p - Vector3(0.0, WATER_TOP - 0.03, 0.0),
		Vector3(STREAM_HALF_X, 0.03, STREAM_HALF_Z))

func _banks(p: Vector3) -> float:
	## 两侧堤岸：各 3 级阶梯石，把溪"切"进草地里
	var d := 1e9
	for sz in [-1.0, 1.0]:
		for i in 3:
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(0.0, 0.06 + i * 0.09, sz * (STREAM_HALF_Z + 0.16 + i * 0.11)),
				Vector3(STREAM_HALF_X, 0.06 + i * 0.09, 0.11)))
	return d

func _deck(p: Vector3) -> float:
	var d := 1e9
	## 木板：沿 Z 均分，每块之间留 0.03 的缝 —— 缝在体素下就是一道阴影线
	var step := (DECK_HALF_Z * 2.0) / PLANKS
	for i in PLANKS:
		var cz := -DECK_HALF_Z + step * (i + 0.5)
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, DECK_Y - 0.07, cz),
			Vector3(DECK_HALF_X, 0.07, step * 0.5 - 0.015)))
	## 两根纵梁（桥面下的承重）：沿 Z 通长
	for sx in [-0.42, 0.42]:
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(sx, DECK_Y - 0.20, 0.0),
			Vector3(0.09, 0.13, DECK_HALF_Z)))
	## 桥墩：两岸各一组石块
	for sz in [-0.88, 0.88]:
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 0.20, sz), Vector3(0.46, 0.20, 0.20)))
	return d

func _rails(p: Vector3) -> float:
	var d := 1e9
	for sx in [-RAIL_X, RAIL_X]:
		## 扶手：通长一根
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(sx, DECK_Y + 0.52, 0.0), Vector3(0.06, 0.06, DECK_HALF_Z)))
		## 立柱：每 0.52 米一根 —— 立栏杆是"这是桥"最强的识别特征
		var n := 5
		for i in n:
			var cz := -DECK_HALF_Z + 0.26 + i * ((DECK_HALF_Z * 2.0 - 0.52) / (n - 1))
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(sx, DECK_Y + 0.26, cz), Vector3(0.05, 0.26, 0.05)))
	return d

func local_bounds() -> AABB:
	return AABB(Vector3(-1.70, -0.05, -1.15), Vector3(3.40, 1.05, 2.30))

func build(_field: SdfField) -> void:
	fill_shape(func(p: Vector3) -> float:
		var d := _water(p)
		d = SdfTool.op_union(d, _banks(p))
		d = SdfTool.op_union(d, _deck(p))
		d = SdfTool.op_union(d, _rails(p))
		return d)

func voxel_regions() -> Array:
	var b := local_bounds()
	return [
		## ① 水面：只在 |z| < 溪半宽 且 y 很矮的地方
		MedievalSkin.box(Vector3(0.0, WATER_TOP - 0.03, 0.0),
			Vector3(STREAM_HALF_X * 2.0, 0.06, STREAM_HALF_Z * 2.0), MedievalSkin.WATER),
		## ② 栏杆扶手（深木棕）
		MedievalSkin.box(Vector3(0.0, DECK_Y + 0.52, 0.0),
			Vector3(RAIL_X * 2.0 + 0.14, 0.14, DECK_HALF_Z * 2.0), MedievalSkin.WOOD),
		## ③ 桥面（浅木黄）
		MedievalSkin.band_y(DECK_Y - 0.28, DECK_Y + 0.06, 0.80, MedievalSkin.WOOD_LT),
		## ④ 兜底：堤岸石
		MedievalSkin.all(b, MedievalSkin.DIRT),
	]

func meta() -> Dictionary:
	return {
		&"tag": "bridge",
		&"surface_snap": true,
		&"wants_ground": true,
		&"face_dir": Vector3i(1, 0, 0),
	}
