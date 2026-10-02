@tool
class_name VoxelSquareBaseGen
extends PropGen
## 用例四的方形体素底座 —— 整个 diorama 站在它上面
##
## ## 造型为什么只有两块
## 用例四要求"边缘由统一正方体单元构成"。这句话在体素语境下**不需要任何几何技巧**：
## 只要底座本身是轴对齐的方块堆叠，提取出来的每一个体素就自然是正方体。
## 反过来说，一旦这里用了圆柱、球或倒角，"边缘由统一正方体"就当场失效 ——
## 所以刻意**只允许 sd_box**，这是约束而不是偷懒。
##
## 两层的错位剖面就是"边缘"的全部表达：外圈低、内圈高，形成一道台阶。
## 底座顶面严格落在 y = 0，摆放层据此贴地。

const HALF := 5.0      ## 半边长（米）。10×10 的方形底座
const THICK := 0.5     ## 总厚
const STEP := 0.16     ## 上层相对下层内收的量 —— 边缘台阶的宽度

func local_bounds() -> AABB:
	return AABB(Vector3(-HALF, -THICK, -HALF), Vector3(HALF * 2.0, THICK, HALF * 2.0))

func build(_field: SdfField) -> void:
	fill_shape(func(p: Vector3) -> float:
		## 下层：通长一块，压住最底
		var lower := SdfTool.sd_box(
			p - Vector3(0.0, -THICK + 0.19, 0.0), Vector3(HALF, 0.19, HALF))
		## 上层：四周内收 STEP，顶面正好 y = 0
		var upper := SdfTool.sd_box(
			p - Vector3(0.0, -0.07, 0.0), Vector3(HALF - STEP, 0.07, HALF - STEP))
		return SdfTool.op_union(lower, upper))

func voxel_regions() -> Array:
	return [
		## 侧壁（台阶立面）：深灰金属，压住底座的分量
		VoxelSkin.band_y(-THICK, -0.14, HALF, VoxelSkin.METAL),
		## 顶面（人行道）：冷灰石。必须是最后一条兜底区 —— 否则未命中体素会落到
		## 按高度分层，在 16 色 swatch 上刷出条纹。
		VoxelSkin.all(local_bounds(), VoxelSkin.STONE),
	]

func meta() -> Dictionary:
	return {
		&"tag": "base",
		&"surface_snap": false,
		&"wants_ground": false,
	}
