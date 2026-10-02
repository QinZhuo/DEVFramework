@tool
class_name VoxelTreeGen
extends PropGen
## 用例四环境 —— 小树（树干 + 三级阶梯树冠）
##
## 用例四把"阶梯过渡"列为独立验收项，屋檐只是其中一种表现。
## 树冠是另一种、更纯粹的一种：**同一种形状靠逐级缩放堆出轮廓**，
## 不用任何曲线或斜面就能让剪影一眼认出是树。
##
## 尺寸带随机抖动（[method prepare]），同一条街上两棵树不会一模一样；
## 但抖的是**整体比例**不是单个体素，所以体素一致性不受影响。

var _h := 1.0     ## 整体缩放

func prepare() -> void:
	_h = rng.randf_range(0.82, 1.18)

## 三级树冠：中心 + 半尺寸。逐级收拢，层厚相同。
func _canopy() -> Array:
	var s := _h
	return [
		[Vector3(0.0, 1.52 * s, 0.0), Vector3(0.82, 0.27, 0.82) * s],
		[Vector3(0.0, 2.02 * s, 0.0), Vector3(0.60, 0.27, 0.60) * s],
		[Vector3(0.0, 2.48 * s, 0.0), Vector3(0.38, 0.24, 0.38) * s],
	]

func local_bounds() -> AABB:
	var s := _h
	return AABB(Vector3(-0.88 * s, 0.0, -0.88 * s), Vector3(1.76 * s, 2.78 * s, 1.76 * s))

func build(_field: SdfField) -> void:
	var canopy := _canopy()
	var s := _h
	fill_shape(func(p: Vector3) -> float:
		## 树干：上细下粗两段，避免一根等粗的棍子
		var d := SdfTool.sd_box(
			p - Vector3(0.0, 0.55 * s, 0.0), Vector3(0.15, 0.55, 0.15) * s)
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 1.20 * s, 0.0), Vector3(0.11, 0.28, 0.11) * s))
		for c in canopy:
			d = SdfTool.op_union(d, SdfTool.sd_box(p - c[0], c[1]))
		return d)

func voxel_regions() -> Array:
	var s := _h
	var out := [
		## 树干
		VoxelSkin.box(Vector3(0.0, 0.86 * s, 0.0),
			Vector3(0.32, 1.72, 0.32) * s, VoxelSkin.BARK),
	]
	## 树冠逐级换色：下层苔绿、顶层提亮，读出体积感。
	## 顶层用 [constant VoxelSkin.LEAF_HI] 而不是"再亮一点的 LEAF"——
	## 色板里没有浅绿时，借 [constant VoxelSkin.WHITE] 会让树顶扣一顶雪帽。
	var cy := _canopy()
	for i in cy.size():
		var c: Array = cy[i]
		var idx := VoxelSkin.LEAF if i < 2 else VoxelSkin.LEAF_HI
		out.append(VoxelSkin.box(c[0], c[1] * 2.0, idx))
	out.append(VoxelSkin.all(local_bounds(), VoxelSkin.LEAF))
	return out

func meta() -> Dictionary:
	return {&"tag": "tree", &"surface_snap": true, &"wants_ground": true}
