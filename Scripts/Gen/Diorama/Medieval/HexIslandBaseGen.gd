@tool
class_name HexIslandBaseGen
extends PropGen
## 用例二底座 —— 六边形草地岛屿，下方四层岩石切面
##
## ## 为什么用六棱柱而不是圆盘 / 方块
## 用例二的验收项写着"六边形草地岛屿底座，边缘有岩石切面"。六棱柱
## （[method SdfTool.sd_prism]，`n=6`）在体素语境下有个额外好处：
## 它的六条边会自然 staircase 成阶梯，比圆盘更容易被读成"低模/体素"
## —— 圆盘在粗体素下会退化成一堆参差不齐的锯齿。
##
## ## 切面怎么来的
## 不做斜切面。**逐级内收的水平层**才是"岩石切面"在体素世界里唯一诚实的表达：
## 每往下一层外接半径收 0.42 米，四层叠出一道厚钝的崖壁。
## 一旦换成真正的斜面（smin/cone），提取出的阶梯宽窄不一，
## 远处看是"边缘毛毛的"，而不是"整齐的切面"。
##
## 顶面严格落在 y = 0，摆放层据此贴地（[member DioramaDef.base_top] = 0）。

## 外接半径（米）。**可用的地面不是 R 而是内切圆 R×cos30° = 5.20** ——
## 六边形六个角的方向有 6.0，六条边中点的方向只有 5.20。
##
## 5.4 → 7.0 是量出来的，不是随手加的：这座岛要装下 10 件单体
## （井 / 两栋屋 / 塔 / 两棵树 / 桥 / 三个村民 / 道具组），
## 它们的 footprint 加起来约 50 m²。真正卡人的不是总面积，而是
## **relax 会把它解不开的重叠一路往外推**——推 1.5 米是常事。
## 实测 6.4 时：木屋中心被推到 3.94（外缘 5.99 > 内切 5.54，屋角悬空 0.45 米）、
## 桥中心被推到 4.22（外缘 6.11）。放到 7.0（内切 6.06）后这些外缘才落回岛面内。
##
## 底座反而**更便宜**：格数按 (2R+margin)/cell 算，R 涨 9% 而 cell 同步从 0.30
## 提到 0.34，净格数从 2.4 万降到 1.3 万 —— 大底座配粗格子，正是低模该有的样子。
const R := 7.0
const TOP_T := 0.20   ## 草皮厚度：y ∈ [-0.20, 0]
const MID_T := 0.30   ## 风化岩层：y ∈ [-0.50, -0.20]
const STEPS := 4      ## 岩石切面层数
const STEP_H := 0.28  ## 每层厚
const STEP_IN := 0.42 ## 每层每侧内收

func local_bounds() -> AABB:
	var bottom := -TOP_T - MID_T - STEPS * STEP_H
	return AABB(Vector3(-R - 0.1, bottom, -R - 0.1),
		Vector3((R + 0.1) * 2.0, -bottom, (R + 0.1) * 2.0))

func build(_field: SdfField) -> void:
	fill_shape(func(p: Vector3) -> float:
		var d := 1e9
		## ① 草皮顶面 —— 不做起伏：道具要贴地，起伏会让每一件都悬空或半埋
		d = SdfTool.op_union(d, SdfTool.sd_prism(
			p - Vector3(0.0, -TOP_T * 0.5, 0.0), R, TOP_T * 0.5, 6))
		## ② 风化层：比草皮略收，露出一道浅色岩线，把"草"与"石"在侧面切开
		d = SdfTool.op_union(d, SdfTool.sd_prism(
			p - Vector3(0.0, -TOP_T - MID_T * 0.5, 0.0), R - 0.08, MID_T * 0.5, 6))
		## ③ 四层岩石切面，逐层内收
		var y := -TOP_T - MID_T
		var r := R - STEP_IN
		for i in STEPS:
			d = SdfTool.op_union(d, SdfTool.sd_prism(
				p - Vector3(0.0, y - STEP_H * 0.5, 0.0), r, STEP_H * 0.5, 6))
			y -= STEP_H
			r -= STEP_IN
		return d)

func voxel_regions() -> Array:
	var b := local_bounds()
	return [
		## ① 岩石切面：草皮以下全是岩灰
		MedievalSkin.band_y(b.position.y, -TOP_T, R, MedievalSkin.ROCK),
		## ② 兜底：草皮奶油绿。必须最后一条，理由见 MedievalSkin 文件头。
		MedievalSkin.all(b, MedievalSkin.GRASS),
	]

func meta() -> Dictionary:
	return {
		&"tag": "hex_base",
		&"surface_snap": false,
		&"wants_ground": false,
	}
