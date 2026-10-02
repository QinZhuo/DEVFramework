@tool
class_name TownhouseGen
extends PropGen
## 用例四环境 —— 面包店两侧的邻楼（两层，比主体矮一截）
##
## 存在的理由不是"多一座楼"，而是给主体一个**高度与体量的参照**：
## 主体三层 7.9 米，邻楼两层 5.4 米，两者并排时观众才会下意识确认"那是三层"。
## 单独看主体时，三层和两层在剪影上是分不出来的。
##
## 造型语言与 [BakeryShopGen] 完全一致（纯盒体 + 阶梯屋顶 + 退线分楼），
## 否则同一条街上出现两种画风，比少一座楼更伤。

const INSET := 0.14
const FRONT := 1.3
const H1 := 2.5
const H2 := 2.3

var _wins: Array = []

func _win(cx: float, cy: float) -> Dictionary:
	return {
		&"cut": Vector3(cx, cy, FRONT),
		&"cut_h": Vector3(0.17, 0.30, 0.26),
		&"pane": Vector3(cx, cy, FRONT - 0.07),
		&"pane_h": Vector3(0.13, 0.26, 0.06),
	}

func prepare() -> void:
	_wins = []
	for x in [-0.62, 0.62]:
		_wins.append(_win(x, 1.30))
	for x in [-0.72, 0.0, 0.72]:
		_wins.append(_win(x, H1 + 1.15))

func local_bounds() -> AABB:
	return AABB(Vector3(-1.48, 0.0, -1.44), Vector3(2.96, 5.6, 2.88))

func build(_field: SdfField) -> void:
	var wins := _wins
	fill_shape(func(p: Vector3) -> float:
		var d := 1e9
		## 两层墙，二层内收
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, H1 * 0.5, 0.0), Vector3(1.3, H1 * 0.5, FRONT)))
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, H1 + H2 * 0.5, 0.0),
			Vector3(1.3 - INSET, H2 * 0.5, FRONT - INSET)))
		## 两道屋檐
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, H1, 0.0), Vector3(1.48, 0.08, FRONT + 0.18)))
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, H1 + H2, 0.0), Vector3(1.34, 0.08, FRONT + 0.04)))
		## 三级阶梯屋顶
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, H1 + H2 + 0.16, 0.0), Vector3(1.16, 0.06, FRONT - 0.12)))
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, H1 + H2 + 0.32, 0.0), Vector3(0.88, 0.06, FRONT - 0.30)))
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, H1 + H2 + 0.48, 0.0), Vector3(0.58, 0.06, FRONT - 0.46)))

		## 门洞 + 门板
		d = SdfTool.op_sub(d, SdfTool.sd_box(
			p - Vector3(0.0, 0.85, FRONT), Vector3(0.34, 0.85, 0.26)))
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 0.82, FRONT - 0.14), Vector3(0.29, 0.82, 0.07)))
		## 窗
		for w in wins:
			d = SdfTool.op_sub(d, SdfTool.sd_box(p - w[&"cut"], w[&"cut_h"]))
			d = SdfTool.op_union(d, SdfTool.sd_box(p - w[&"pane"], w[&"pane_h"]))
		return d)

func voxel_regions() -> Array:
	var out := []
	for w in _wins:
		out.append(VoxelSkin.box(w[&"pane"], w[&"pane_h"] * 2.0, VoxelSkin.WINDOW))
	## 门板与门框
	out.append(VoxelSkin.box(Vector3(0.0, 0.82, FRONT - 0.14),
		Vector3(0.58, 1.64, 0.14), VoxelSkin.WOOD))
	for fx in [-0.45, 0.45]:
		out.append(VoxelSkin.box(Vector3(fx, 0.85, FRONT + 0.02),
			Vector3(0.20, 1.86, 0.12), VoxelSkin.WOOD))
	## 屋顶
	out.append(VoxelSkin.band_y(H1 + H2 + 0.10, H1 + H2 + 0.56, 1.5, VoxelSkin.ROOF))
	## 屋檐
	for y in [H1, H1 + H2]:
		out.append(VoxelSkin.band_y(y - 0.08, y + 0.08, 1.5, VoxelSkin.WOOD))
	## 二层外墙
	out.append(VoxelSkin.band_y(H1, H1 + H2 + 0.10, 1.5, VoxelSkin.SAND))
	## 兜底
	out.append(VoxelSkin.all(local_bounds(), VoxelSkin.CREAM))
	return out

func meta() -> Dictionary:
	return {&"tag": "townhouse", &"surface_snap": true, &"wants_ground": true}
