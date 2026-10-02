@tool
class_name StylizedTreeGen
extends PropGen
## 用例二环境 —— 风格化树木：六棱树干 + 三层阶梯树冠
##
## JRPG 低模树的通行写法就是**三层由大到小叠上去**，这里照做，但每层用六棱柱
## 而不是球：球体在体素下会变成一团没有方向的疙瘩，而棱柱每层的六个角
## 在下一层顶面投下六道小阴影 —— 树冠的"体积感"全靠这些角，不靠面。
##
## 顶层额外给一格浅绿（[constant MedievalSkin.LEAF] 之外的提亮色是没有的，
## 所以顶层改用 [constant MedievalSkin.EMBER] 之外的做法：直接在区域表里
## 把顶层单独切给 [constant MedievalSkin.GRASS]），让树冠顶看起来是被光打亮的。

const TRUNK_R := 0.17     ## 树干外接半径
const TRUNK_H := 1.30     ## 树干高
const TIERS := 3          ## 树冠层数
const TIER_T := 0.52      ## 每层厚
const TIER_R0 := 0.95     ## 最下层外接半径
const TIER_Y0 := 1.05     ## 最下层底（与树干有 0.25 的咬合）

func local_bounds() -> AABB:
	return AABB(Vector3(-1.05, 0.0, -1.05),
		Vector3(2.10, TIER_Y0 + TIERS * TIER_T + 0.20, 2.10))

func build(_field: SdfField) -> void:
	fill_shape(func(p: Vector3) -> float:
		var d := SdfTool.sd_prism(
			p - Vector3(0.0, TRUNK_H * 0.5, 0.0), TRUNK_R, TRUNK_H * 0.5, 6)
		var y := TIER_Y0
		var rr := TIER_R0
		for i in TIERS:
			d = SdfTool.op_union(d, SdfTool.sd_prism(
				p - Vector3(0.0, y + TIER_T * 0.5, 0.0), rr, TIER_T * 0.5, 6))
			y += TIER_T * 0.86      ## 层间留 14% 咬合，避免层与层之间出现缝
			rr -= 0.24
		return d)

func voxel_regions() -> Array:
	var b := local_bounds()
	return [
		## ① 顶层树冠：提亮的浅绿（受光面）
		MedievalSkin.band_y(TIER_Y0 + TIER_T * 1.72, b.size.y, 1.0,
			MedievalSkin.GRASS),
		## ② 树干
		MedievalSkin.band_y(0.0, TIER_Y0 + 0.10, 0.30, MedievalSkin.TRUNK),
		## ③ 兜底：树冠深绿
		MedievalSkin.all(b, MedievalSkin.LEAF),
	]

func meta() -> Dictionary:
	return {
		&"tag": "tree",
		&"surface_snap": true,
		&"wants_ground": true,
	}
