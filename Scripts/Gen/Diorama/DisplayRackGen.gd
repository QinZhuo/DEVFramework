@tool
class_name DisplayRackGen
extends PropGen
## 用例四道具 —— 门口的面包展示架
##
## 用例四把"体素化面包展示架"写进道具清单，验收项里"场景完整度"考的就是
## "面包店、街道、路灯、长椅、顾客是否组成完整街角"。也就是说**面包本身必须看得见**——
## 一个空货架不成立。所以这里把面包做成实心块摆在架板上，而不是靠贴图暗示。
##
## 面包用两级阶梯（底大顶小），不用球 —— 球会被体素化成"阶梯的球"，
## 远看像一颗掉色的球，两级方块反而更像刚出炉的面包。

const W := 0.62    ## 半宽
const D := 0.28    ## 半深
const H := 1.32    ## 总高

## 两层层板 + 每层 3 只面包（共 6 只，摆放位置由 _breads 固定）
func _shelves() -> Array:
	return [
		[Vector3(0.0, 0.92, 0.0), Vector3(W - 0.06, 0.04, D - 0.04)],
		[Vector3(0.0, 1.18, 0.0), Vector3(W - 0.06, 0.04, D - 0.04)],
	]

func _breads() -> Array:
	var out := []
	for sy in [0.99, 1.25]:
		for i in 3:
			var x := -0.36 + 0.36 * float(i)
			out.append([Vector3(x, sy, 0.0), Vector3(0.11, 0.045, 0.085)])
			out.append([Vector3(x, sy + 0.075, 0.0), Vector3(0.075, 0.035, 0.055)])
	return out

func local_bounds() -> AABB:
	return AABB(Vector3(-W, 0.0, -D), Vector3(W * 2.0, H, D * 2.0))

func build(_field: SdfField) -> void:
	var shelves := _shelves()
	var breads := _breads()
	fill_shape(func(p: Vector3) -> float:
		## 台柜
		var d := SdfTool.sd_box(p - Vector3(0.0, 0.42, 0.0),
			Vector3(W, 0.42, D))
		## 背板：让货架从背后看也是实的
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 0.88, -D + 0.03), Vector3(W, 0.46, 0.03)))
		## 层板
		for s in shelves:
			d = SdfTool.op_union(d, SdfTool.sd_box(p - s[0], s[1]))
		## 面包
		for b in breads:
			d = SdfTool.op_union(d, SdfTool.sd_box(p - b[0], b[1]))
		## 顶篷：三级阶梯，把展架也做成一栋小建筑，和街上的体素语言对齐
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 1.28, 0.0), Vector3(W + 0.10, 0.05, D + 0.10)))
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 1.38, -0.02), Vector3(W, 0.05, D)))
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, 1.48, -0.04), Vector3(W - 0.16, 0.05, D - 0.12)))
		return d)

func voxel_regions() -> Array:
	var out := []
	for b in _breads():
		out.append(VoxelSkin.box(b[0], b[1] * 2.0, VoxelSkin.BREAD))
	## 层板与顶篷：奶白
	for s in _shelves():
		out.append(VoxelSkin.box(s[0], s[1] * 2.0, VoxelSkin.WHITE))
	out.append(VoxelSkin.band_y(1.23, 1.53, W + 0.1, VoxelSkin.WHITE))
	## 台柜与背板：木色
	out.append(VoxelSkin.band_y(0.0, 0.88, W, VoxelSkin.WOOD))
	out.append(VoxelSkin.all(local_bounds(), VoxelSkin.WOOD))
	return out

func meta() -> Dictionary:
	return {&"tag": "display", &"surface_snap": true, &"wants_ground": true}
