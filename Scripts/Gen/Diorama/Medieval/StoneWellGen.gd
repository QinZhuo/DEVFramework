@tool
class_name StoneWellGen
extends PropGen
## 用例二主体 —— 广场中央的石井：八棱井圈 + 木架 + 阶梯金字塔顶 + 吊桶
##
## 两条造型自律（用例二"低多边形"验收项的直接对应）：
## · **圆一概用棱柱**。井圈用八棱柱、吊桶用六棱柱。真圆盘被体素化后边缘会歪成
##   参差锯齿，而棱柱阶梯出来的正是低模该有的样子。
## · **尖顶只能用阶梯**。真斜面在粗体素下会变成宽窄随机的锯齿，而"逐级每边收
##   半个方块"叠出的金字塔，本身就已是一个正确的 low-poly 锥体。
##
## 分色见 [MedievalSkin] 的索引常量。

## 占地 2.4×2.4。刻意压到这么小：井站在**圆心**，而三个村民站在 band 0（半径 1.7）
## 围着它 —— 井一旦做到 3.1 米宽，它的避让圆就把整圈村民全顶住，
## relax 的连锁推动会把外圈的树与桥一路推到岛外（实测：桥中心被推到半径 4.4）。
## "广场中央的井"要的是**周围留得出走动的余地**，井本身小一点才对。
const RR := 0.82        ## 井圈外接半径（米）
const WELL_H := 1.05    ## 井圈高
const POST_H := 2.35    ## 两根立柱高
const POST_X := 0.68    ## 立柱间距的半值
const ROOF_STEPS := 4   ## 金字塔顶级数
const ROOF_BASE := 1.12 ## 顶檐半宽（含挑檐）
const ROOF_Y0 := 2.55   ## 顶檐起始高度
const WATER_Y := 0.60   ## 井腔内水面 y

## 井身：八棱柱 + 井口三级石环 + 掏空的井腔
func _well(p: Vector3) -> float:
	var d := SdfTool.sd_prism(p - Vector3(0.0, WELL_H * 0.5, 0.0), RR, WELL_H * 0.5, 8)
	for i in 3:
		var rr := RR + 0.16 - i * 0.20
		d = SdfTool.op_union(d, SdfTool.sd_prism(
			p - Vector3(0.0, WELL_H + 0.07 + i * 0.14, 0.0), rr, 0.07, 8))
	d = SdfTool.op_sub(d, SdfTool.sd_prism(
		p - Vector3(0.0, 0.60, 0.0), RR - 0.30, 0.70, 8))
	return d

## 木架：两柱 + 横梁 + 六棱辘轳
func _posts(p: Vector3) -> float:
	var d := 1e9
	for sx in [-POST_X, POST_X]:
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(sx, POST_H * 0.5, 0.0), Vector3(0.13, POST_H * 0.5, 0.13)))
	d = SdfTool.op_union(d, SdfTool.sd_box(
		p - Vector3(0.0, POST_H - 0.10, 0.0), Vector3(POST_X + 0.22, 0.14, 0.15)))
	d = SdfTool.op_union(d, SdfTool.sd_prism(
		p - Vector3(0.0, POST_H + 0.10, 0.0), 0.22, 0.10, 6))
	return d

## 四层阶梯金字塔顶
func _roof(p: Vector3) -> float:
	var d := 1e9
	var y := ROOF_Y0
	var hw := ROOF_BASE
	for i in ROOF_STEPS:
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, y, 0.0), Vector3(hw, 0.08, hw)))
		y += 0.17
		hw = maxf(hw - 0.34, 0.30)
	return d

## 吊桶：一段细绳 + 六棱水桶 + 一道桶箍
func _bucket(p: Vector3) -> float:
	var top := POST_H - 0.24
	var rope := SdfTool.sd_box(
		p - Vector3(0.0, top - 0.22, 0.0), Vector3(0.045, 0.22, 0.045))
	var b := SdfTool.sd_prism(p - Vector3(0.0, top - 0.56, 0.0), 0.19, 0.13, 6)
	b = SdfTool.op_union(b, SdfTool.sd_prism(
		p - Vector3(0.0, top - 0.44, 0.0), 0.205, 0.025, 6))
	return SdfTool.op_union(rope, b)

func local_bounds() -> AABB:
	return AABB(Vector3(-1.20, 0.0, -1.20), Vector3(2.40, 3.80, 2.40))

func build(_field: SdfField) -> void:
	fill_shape(func(p: Vector3) -> float:
		var d := _well(p)
		d = SdfTool.op_union(d, _posts(p))
		d = SdfTool.op_union(d, _roof(p))
		d = SdfTool.op_union(d, _bucket(p))
		## 水面：井腔底部一薄片，只在正上方可见
		d = SdfTool.op_union(d, SdfTool.sd_prism(
			p - Vector3(0.0, WATER_Y, 0.0), RR - 0.28, 0.06, 8))
		return d)

func voxel_regions() -> Array:
	var b := local_bounds()
	return [
		## ① 顶檐四层：靛蓝瓦
		MedievalSkin.band_y(ROOF_Y0 - 0.10, ROOF_Y0 + ROOF_STEPS * 0.17, 1.2,
			MedievalSkin.ROOF_BLUE),
		## ② 木架与吊桶：深木棕（含辘轳）
		MedievalSkin.band_y(POST_H - 0.30, ROOF_Y0 - 0.10, 1.0, MedievalSkin.WOOD),
		## ③ 井腔内水面
		MedievalSkin.box(Vector3(0.0, WATER_Y, 0.0),
			Vector3((RR - 0.28) * 2.0, 0.14, (RR - 0.28) * 2.0), MedievalSkin.WATER),
		## ④ 井口石环（井圈顶面以上）：深石灰，压出井沿的阴影线
		MedievalSkin.band_y(WELL_H, WELL_H + 0.50, 1.0, MedievalSkin.STONE_DK),
		## ⑤ 兜底：井身石墙灰
		MedievalSkin.all(b, MedievalSkin.STONE),
	]

func meta() -> Dictionary:
	return {
		&"tag": "well",
		&"surface_snap": true,
		&"wants_ground": true,
		&"face_dir": Vector3i(0, 0, 1),
	}
