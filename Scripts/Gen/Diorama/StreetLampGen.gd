@tool
class_name StreetLampGen
extends PropGen
## 用例四环境 —— 路灯（杆 + 悬臂 + 灯头）
##
## 灯头是全场唯一的**第二光源暗示**：分色用 [constant VoxelSkin.LAMP]（亮黄）。
## 体素场景里"发光"靠颜色区分，不靠 bloom —— bloom 会把体素硬边糊掉，
## 恰好毁掉这个风格最值钱的东西。

const H := 2.95      ## 灯头中心高
const REACH := 0.55  ## 悬臂伸出

func local_bounds() -> AABB:
	return AABB(Vector3(-0.22, 0.0, -0.22), Vector3(REACH + 0.44, H + 0.24, 0.44))

func build(_field: SdfField) -> void:
	fill_shape(func(p: Vector3) -> float:
		## 底座
		var d := SdfTool.sd_box(p - Vector3(0.0, 0.07, 0.0), Vector3(0.19, 0.07, 0.19))
		## 灯杆
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, H * 0.5, 0.0), Vector3(0.07, H * 0.5, 0.07)))
		## 悬臂：两段折角，比一根直挑更有机械感
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(REACH * 0.5, H - 0.06, 0.0),
			Vector3(REACH * 0.5, 0.07, 0.07)))
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(REACH * 0.62, H + 0.14, 0.0), Vector3(0.07, 0.14, 0.07)))
		## 灯头：倒梯形，两级收拢
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(REACH, H - 0.06, 0.0), Vector3(0.17, 0.07, 0.17)))
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(REACH, H - 0.18, 0.0), Vector3(0.12, 0.08, 0.12)))
		## 灯罩下的发光面
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(REACH, H - 0.27, 0.0), Vector3(0.10, 0.06, 0.10)))
		return d)

func voxel_regions() -> Array:
	return [
		## 灯罩发光面（先判，否则会被下面的灯头盒抢走）
		VoxelSkin.box(Vector3(REACH, H - 0.27, 0.0),
			Vector3(0.20, 0.07, 0.20), VoxelSkin.LAMP),
		## 灯头
		VoxelSkin.box(Vector3(REACH, H - 0.12, 0.0),
			Vector3(0.34, 0.24, 0.34), VoxelSkin.METAL),
		VoxelSkin.all(local_bounds(), VoxelSkin.METAL),
	]

func meta() -> Dictionary:
	return {&"tag": "lamp", &"surface_snap": true, &"wants_ground": true}
