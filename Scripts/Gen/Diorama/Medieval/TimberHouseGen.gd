@tool
class_name TimberHouseGen
extends PropGen
## 用例二环境 —— 两层木屋：一层石墙 + 二层外挑木墙 + 阶梯坡顶 + 烟囱
##
## "两层"这件事必须**在剪影上就能读出来**，靠两件事：
## · 二层比一层**宽**（外挑 0.11 米）而不是窄 —— 中世纪木构就是这样，
##   而且外挑会在一层顶上投下一道硬阴影线，等于免费画出了一条楼层分界。
## · 楼层之间夹一道 0.12 米厚的木楼板带（[constant FLOOR_BAND]），
##   它是"退线"的低模写法：不贴腰线贴图，直接挤出一条实体。
##
## ## 尺寸是量过的，不是随手给的
## 占地 2.30×1.90（footprint 约 2.5×2.1）。这座岛的内切圆只有 4.68 米
## （见 [HexIslandBaseGen]），而屋后还要站一座塔 —— 房子一旦做到 3.9 米宽，
## 两者加起来的弦长就超过内切圆，relax 会把它们一路推到岛外（实测：房屋中心
## 落在半径 4.94 处，半栋悬空）。"微缩"本来就该是这个尺度。
##
## 屋顶走阶梯金字塔（见 [StoneWellGen] 文件头），烟囱是两段方盒 ——
## 方形烟囱在体素下能被读成砖砌，圆柱不行。

const HALF1 := Vector3(1.15, 1.15, 0.95)   ## 一层石墙半尺寸，y ∈ [0, 2.30]
const HALF2 := Vector3(1.26, 0.95, 1.06)   ## 二层木墙半尺寸，y ∈ [2.42, 4.32]
const FLOOR_BAND := 0.12                   ## 二层楼板带厚
const ROOF_STEPS := 4                      ## 坡顶级数
const ROOF_HALF := 1.50                    ## 顶檐半宽（含挑檐）
const ROOF_Y0 := 4.38                      ## 顶檐起始高度
const FRONT := 0.95                        ## 一层正面 z（+Z 为正面）

const WIN1 := Vector2(0.22, 0.30)
const WIN2 := Vector2(0.18, 0.25)
const PANE1 := Vector2(0.17, 0.25)
const PANE2 := Vector2(0.14, 0.20)

var _wins: Array = []

func _win(center: Vector3, cut: Vector2, pane: Vector2) -> Dictionary:
	return {
		&"cut_c": center, &"cut_h": Vector3(cut.x, cut.y, 0.28),
		&"pane_c": Vector3(center.x, center.y, center.z - 0.10),
		&"pane_h": Vector3(pane.x, pane.y, 0.10),
	}

func prepare() -> void:
	_wins = [
		_win(Vector3(-0.72, 1.28, FRONT), WIN1, PANE1),
		_win(Vector3(0.72, 1.28, FRONT), WIN1, PANE1),
		_win(Vector3(-0.68, 3.10, HALF2.z), WIN2, PANE2),
		_win(Vector3(0.04, 3.10, HALF2.z), WIN2, PANE2),
		_win(Vector3(0.76, 3.10, HALF2.z), WIN2, PANE2),
	]

func local_bounds() -> AABB:
	return AABB(Vector3(-1.58, 0.0, -1.30),
		Vector3(3.16, ROOF_Y0 + ROOF_STEPS * 0.19 + 0.28, 2.68))

func build(_field: SdfField) -> void:
	var wins := _wins
	fill_shape(func(p: Vector3) -> float:
		var d := SdfTool.sd_box(p - Vector3(0.0, HALF1.y, 0.0), HALF1)
		## 楼板带：比一层宽 0.11 ⇒ 二层是"外挑"的，剪影上自带一条阴影线
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 2.30 + FLOOR_BAND * 0.5, 0.0),
			Vector3(HALF2.x, FLOOR_BAND * 0.5, HALF2.z)))
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 2.30 + FLOOR_BAND + HALF2.y, 0.0), HALF2))
		## 二层四根外露木柱 —— 这就是 "half-timber" 的读法
		for sx in [-1.12, 1.12]:
			for sz in [-0.90, 0.90]:
				d = SdfTool.op_union(d, SdfTool.sd_box(
					p - Vector3(sx, 3.36, sz), Vector3(0.08, 0.94, 0.08)))
		var y := ROOF_Y0
		var hw := ROOF_HALF
		for i in ROOF_STEPS:
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(0.0, y, 0.0), Vector3(hw, 0.09, hw)))
			y += 0.19
			hw = maxf(hw - 0.35, 0.30)
		## 烟囱：贴在后墙外侧，两段方盒
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(-0.82, 3.60, -1.06), Vector3(0.19, 1.35, 0.19)))
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(-0.82, 4.92, -1.06), Vector3(0.24, 0.09, 0.24)))
		## 门洞 + 门板 + 门框
		d = SdfTool.op_sub(d, SdfTool.sd_box(
			p - Vector3(0.0, 0.82, FRONT), Vector3(0.30, 0.82, 0.26)))
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 0.78, FRONT - 0.13), Vector3(0.25, 0.78, 0.08)))
		for fx in [-0.38, 0.38]:
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(fx, 0.82, FRONT + 0.02), Vector3(0.09, 0.92, 0.12)))
		for w in wins:
			d = SdfTool.op_sub(d, SdfTool.sd_box(p - w[&"cut_c"], w[&"cut_h"]))
			d = SdfTool.op_union(d, SdfTool.sd_box(p - w[&"pane_c"], w[&"pane_h"]))
		return d)

func voxel_regions() -> Array:
	var b := local_bounds()
	var out := []
	for w in _wins:
		out.append(MedievalSkin.box(w[&"pane_c"], w[&"pane_h"] * 2.0, MedievalSkin.EMBER))
	out.append(MedievalSkin.band_y(ROOF_Y0 - 0.12,
		ROOF_Y0 + ROOF_STEPS * 0.19, 1.6, MedievalSkin.ROOF_RED))
	out.append(MedievalSkin.band_y(2.30, ROOF_Y0 - 0.12, 1.4, MedievalSkin.WOOD_LT))
	out.append(MedievalSkin.box(Vector3(-0.82, 3.60, -1.06),
		Vector3(0.48, 2.80, 0.48), MedievalSkin.STONE_DK))
	for fx in [-0.38, 0.38]:
		out.append(MedievalSkin.box(Vector3(fx, 0.82, FRONT + 0.02),
			Vector3(0.18, 1.84, 0.24), MedievalSkin.WOOD))
	out.append(MedievalSkin.all(b, MedievalSkin.STONE))
	return out

func meta() -> Dictionary:
	return {
		&"tag": "house",
		&"surface_snap": true,
		&"wants_ground": true,
		&"face_dir": Vector3i(0, 0, 1),
	}
