@tool
class_name WatchTowerGen
extends PropGen
## 用例二环境 —— 小型石制瞭望塔：石基 + 八棱塔身 + 外挑平台 + 阶梯锥顶
##
## 与木屋刻意做成**同一条语法的不同变体**：一样的阶梯金字塔顶，但塔身是八棱柱、
## 底部多两级收分、顶上多一圈外挑平台。这样"塔"和"屋"一眼是同一座村子里的东西，
## 而不是两批不同来源的资产 —— 用例二验收项里"色调统一"指的就是这个。
##
## 平台用「大一圈的扁八棱柱」而不是圆环：环形在体素下会碎成一圈散点，
## 扁棱柱能保住一整块连续的挑檐下表面（那是阴影落的地方，最要紧）。

## 尺寸按"岛的内切圆 4.68 米"反推：塔要站在两栋木屋中间（弧心 90°，边中点方向），
## 自身半宽 1.12 + 站位半径 3.10 = 4.22，留出 0.46 的余量给 relax 推挤。
const PLINTH_STEPS := 2    ## 石基收分级数
const PLINTH_HALF := 1.05  ## 石基最下级半宽
const BODY_R := 0.70       ## 塔身外接半径
const BODY_Y0 := 0.60      ## 塔身底
const BODY_TOP := 3.50     ## 塔身顶
const DECK_HALF := 0.95    ## 外挑平台半宽
const DECK_T := 0.26       ## 平台厚
const CONE_STEPS := 5      ## 锥顶级数
const CONE_HALF := 0.88    ## 锥底半宽
const CONE_Y0 := 3.86      ## 锥底高度

func _plinth(p: Vector3) -> float:
	var d := 1e9
	var y := 0.15
	var hw := PLINTH_HALF
	for i in PLINTH_STEPS:
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, y, 0.0), Vector3(hw, 0.15, hw)))
		y += 0.30
		hw -= 0.18
	return d

func _body(p: Vector3) -> float:
	var h := BODY_TOP - BODY_Y0
	var d := SdfTool.sd_prism(
		p - Vector3(0.0, BODY_Y0 + h * 0.5, 0.0), BODY_R, h * 0.5, 8)
	## 三道石砌腰线：扁棱柱外挑 0.06，纯剪影装饰
	for yy in [1.40, 2.30]:
		d = SdfTool.op_union(d, SdfTool.sd_prism(
			p - Vector3(0.0, yy, 0.0), BODY_R + 0.07, 0.05, 8))
	return d

func _deck(p: Vector3) -> float:
	## 平台：挑檐 + 一圈女儿墙（外圈扁棱柱减内圈）
	var slab := SdfTool.sd_box(
		p - Vector3(0.0, BODY_TOP + DECK_T * 0.5, 0.0),
		Vector3(DECK_HALF, DECK_T * 0.5, DECK_HALF))
	var rail := SdfTool.sd_box(
		p - Vector3(0.0, BODY_TOP + DECK_T + 0.18, 0.0),
		Vector3(DECK_HALF, 0.18, DECK_HALF))
	rail = SdfTool.op_sub(rail, SdfTool.sd_box(
		p - Vector3(0.0, BODY_TOP + DECK_T + 0.18, 0.0),
		Vector3(DECK_HALF - 0.16, 0.30, DECK_HALF - 0.16)))
	return SdfTool.op_union(slab, rail)

func _cone(p: Vector3) -> float:
	var d := 1e9
	var y := CONE_Y0
	var hw := CONE_HALF
	for i in CONE_STEPS:
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, y, 0.0), Vector3(hw, 0.10, hw)))
		y += 0.22
		hw = maxf(hw - 0.20, 0.22)
	return d

func local_bounds() -> AABB:
	return AABB(Vector3(-1.12, 0.0, -1.12),
		Vector3(2.24, CONE_Y0 + CONE_STEPS * 0.22 + 0.24, 2.24))

func build(_field: SdfField) -> void:
	fill_shape(func(p: Vector3) -> float:
		var d := _plinth(p)
		d = SdfTool.op_union(d, _body(p))
		d = SdfTool.op_union(d, _deck(p))
		d = SdfTool.op_union(d, _cone(p))
		## 塔身两处箭窗：挖穿的小洞，不嵌亮面（塔里没人点灯）
		for a in [0.0, PI * 0.5]:
			var c := Vector3(cos(a) * (BODY_R - 0.05), 2.85, sin(a) * (BODY_R - 0.05))
			d = SdfTool.op_sub(d, SdfTool.sd_box(p - c, Vector3(0.16, 0.26, 0.40)))
		return d)

func voxel_regions() -> Array:
	var b := local_bounds()
	return [
		## ① 锥顶（靛蓝瓦）—— 与木屋的陶红形成"一冷一暖"的对子
		MedievalSkin.band_y(CONE_Y0 - 0.12, CONE_Y0 + CONE_STEPS * 0.22, 1.2,
			MedievalSkin.ROOF_BLUE),
		## ② 外挑平台与女儿墙（深木棕）
		MedievalSkin.band_y(BODY_TOP, CONE_Y0 - 0.12, 1.3, MedievalSkin.WOOD),
		## ③ 石基（深石灰）
		MedievalSkin.band_y(0.0, BODY_Y0, 1.4, MedievalSkin.STONE_DK),
		## ④ 兜底：塔身石墙灰
		MedievalSkin.all(b, MedievalSkin.STONE),
	]

func meta() -> Dictionary:
	return {
		&"tag": "tower",
		&"surface_snap": true,
		&"wants_ground": true,
		&"face_dir": Vector3i(0, 0, 1),
	}
