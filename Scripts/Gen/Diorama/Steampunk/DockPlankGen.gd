@tool
class_name DockPlankGen
extends PropGen
## 用例五环境 —— 木质码头：甲板 + 四根桩 + 两段铁轨 + 两个缆桩
##
## ## 甲板的"板"是怎么读出来的
## 不做一块平板 —— 那样在体素下就是一块木头色的大方块。
## 这里沿 Z 方向挖 7 道 0.04 米宽的缝（只挖到甲板厚的一半，不挖穿），
## 于是甲板顶面出现 7 道阴影线，"木板"这件事才成立。
## 挖穿的话缝会漏到底下，从侧面看是一排通天缝，反而像栅栏。
##
## ## 为什么码头与飞艇是两件
## 它们是"停靠"关系，不是"一件物体"。分开后飞艇能被 `y_offset` 抬到半空、
## 码头贴地 —— 这个高度差就是"停靠在旁边"。合成一件的话两者会被同一个 lift
## 拉到同一高度，也就没有了"停靠"。

const HALF_X := 1.80    ## 甲板半长（X）
const HALF_Z := 0.75    ## 甲板半宽（Z）
const DECK_T := 0.20    ## 甲板厚：y ∈ [0, 0.20]
const PILE_Y := -0.28   ## 桩底
const RAIL_Z := 0.52    ## 铁轨距中轴的距离

func local_bounds() -> AABB:
	return AABB(Vector3(-2.00, PILE_Y - 0.05, -0.95),
		Vector3(4.00, DECK_T - PILE_Y + 0.45, 1.90))

func build(_field: SdfField) -> void:
	fill_shape(func(p: Vector3) -> float:
		var d := SdfTool.sd_box(p - Vector3(0.0, DECK_T * 0.5, 0.0),
			Vector3(HALF_X, DECK_T * 0.5, HALF_Z))
		## 板缝：只挖上半层，不挖穿
		for i in 7:
			var z := -HALF_Z + (float(i) + 0.5) * (2.0 * HALF_Z / 7.0)
			d = SdfTool.op_sub(d, SdfTool.sd_box(
				p - Vector3(0.0, DECK_T - 0.05, z), Vector3(HALF_X, 0.06, 0.02)))
		## 四根桩：穿过甲板往下
		for x in [-1.45, 1.45]:
			for z in [-0.55, 0.55]:
				d = SdfTool.op_union(d, SdfTool.sd_cylinder(
					p - Vector3(x, PILE_Y * 0.5 + 0.10, z), 0.32, 0.11))
		## 铁轨：两根沿 X 的细梁，压在甲板面上
		for z in [-RAIL_Z, RAIL_Z]:
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(0.0, DECK_T + 0.035, z), Vector3(HALF_X, 0.035, 0.03)))
		## 缆桩：柱 + 球头，靠在甲板两端
		for x in [-1.55, 1.55]:
			d = SdfTool.op_union(d, SdfTool.sd_cylinder(
				p - Vector3(x, 0.34, -0.45), 0.18, 0.09))
			d = SdfTool.op_union(d, SdfTool.sd_sphere(
				p - Vector3(x, 0.54, -0.45), 0.12))
		return d)

func voxel_regions() -> Array:
	var b := local_bounds()
	return [
		## ① 铁轨（做旧铁）
		SteamSkin.band_y(DECK_T, DECK_T + 0.10, 1.9, SteamSkin.IRON),
		## ② 桩与缆桩（深棕木）
		SteamSkin.band_y(PILE_Y - 0.05, 0.02, 1.9, SteamSkin.WOOD),
		## ③ 兜底：甲板浅木
		SteamSkin.all(b, SteamSkin.WOOD_LT),
	]

func meta() -> Dictionary:
	return {
		&"tag": "dock",
		&"surface_snap": true,
		&"wants_ground": true,
		&"face_dir": Vector3i(1, 0, 0),
	}
