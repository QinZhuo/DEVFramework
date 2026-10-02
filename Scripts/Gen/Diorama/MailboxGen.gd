@tool
class_name MailboxGen
extends PropGen
## 用例四道具 —— 邮筒
##
## 顶盖用**两级阶梯**近似圆弧，不用半圆柱。理由与面包一致：体素化会把曲面切成
## 阶梯，而"阶梯的阶梯"既不是圆也不是方，是噪声。用两级方阶反而读得出来是邮筒。
##
## 立柱 / 顶盖各级的厚度都 ≥ 一个体素边长（0.12 米，见 [constant DioramaPresets.CELL]），
## 否则它们在 0.12 米的格点采样上只有落在采样面上才留得住，落空就整块消失 ——
## 现象是"邮筒只剩一个箱子"，而不是报错。

const HB := 0.21  ## 箱体半宽
const TOP := 1.18 ## 总高

func local_bounds() -> AABB:
	return AABB(Vector3(-HB - 0.03, 0.0, -HB - 0.03),
		Vector3((HB + 0.03) * 2.0, TOP + 0.08, (HB + 0.03) * 2.0))

func build(_field: SdfField) -> void:
	fill_shape(func(p: Vector3) -> float:
		## 底座
		var d := SdfTool.sd_box(p - Vector3(0.0, 0.07, 0.0),
			Vector3(0.17, 0.07, 0.17))
		## 立柱
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 0.34, 0.0), Vector3(0.07, 0.34, 0.07)))
		## 箱体
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 0.86, 0.0), Vector3(HB, 0.17, HB)))
		## 顶盖：两级阶梯近似圆顶（每级 0.14~0.15 米厚，粗过体素才留得住）
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 1.06, 0.0), Vector3(HB - 0.04, 0.07, HB - 0.04)))
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 1.14, 0.0), Vector3(HB - 0.11, 0.075, HB - 0.11)))
		## 投信口：一道横向暗槽
		d = SdfTool.op_sub(d, SdfTool.sd_box(
			p - Vector3(0.0, 0.94, HB), Vector3(0.13, 0.022, 0.04)))
		return d)

func voxel_regions() -> Array:
	var out := [
		## 投信口
		VoxelSkin.box(Vector3(0.0, 0.94, HB), Vector3(0.26, 0.044, 0.08), VoxelSkin.WOOD),
		## 箱体与顶盖：砖红
		VoxelSkin.band_y(0.66, TOP, HB + 0.01, VoxelSkin.AWNING),
	]
	out.append(VoxelSkin.all(local_bounds(), VoxelSkin.METAL))
	return out

func meta() -> Dictionary:
	return {&"tag": "mailbox", &"surface_snap": true, &"wants_ground": true}
