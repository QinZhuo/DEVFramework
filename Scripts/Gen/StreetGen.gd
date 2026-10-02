@tool
class_name StreetGen
extends PropGen
## 街道段 —— 独立单体生成器
##
## 唯一**不贴地**的单体：路面必须严格跟随地形起伏，由布局层决定每段的 y。
## 若让生成器自己贴地，坡道上就会出现台阶。
##
## 沿局部 +X 延伸（可首尾平铺成整条路），路面法线朝 +Z。
## meta.surface_snap = false：布局层收到该标记后按 NONE 处理，
## y 完全由调用方给定或由地形采样提供。

const SEG_LEN := 24.0    ## 单段长度（米，沿 X）
const ROAD_HW := 3.5     ## 路面半宽（米）
const WALK_W := 1.6      ## 人行道宽（米）

var road_hw := 3.5
var walk_w := 1.6
var has_center_line := true

func local_bounds() -> AABB:
	var hw := road_hw + walk_w
	return AABB(
		Vector3(-SEG_LEN * 0.5, -0.55, -hw),
		Vector3(SEG_LEN, 1.1, hw * 2.0))

## 街道占地就是路面本身：人行道与建筑重叠是正常的（店铺门前）
func footprint() -> Vector2:
	return Vector2(SEG_LEN, road_hw * 2.0)

func prepare() -> void:
	road_hw = ROAD_HW * rng.randf_range(0.92, 1.08)
	walk_w = WALK_W * rng.randf_range(0.85, 1.2)
	has_center_line = rng.randf() < 0.75

func build(_field: SdfField) -> void:
	var hw := road_hw
	var ww := walk_w
	var mid := has_center_line
	fill_shape(func(p: Vector3) -> float:
		# 路面板。厚度取 0.4m（真实路面结构层量级）而不是更薄 ——
		# 板太薄时，体素一旦比厚度粗，采样点会整体落在板外，
		# 等值面直接提不出来（烘焙出空网格），且只在"精度调粗"时暴露。
		var d := SdfTool.sd_box(p - Vector3(0, 0, 0), Vector3(SEG_LEN * 0.5, 0.2, hw))
		# 中线：极薄凸起
		if mid:
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(0, 0.2, 0), Vector3(SEG_LEN * 0.5, 0.02, 0.09)))
		# 两侧路缘 + 人行道（比路面高一点）
		for sz in [-1.0, 1.0]:
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(0, 0.1, sz * (hw + 0.1)), Vector3(SEG_LEN * 0.5, 0.26, 0.1)))
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(0, 0.06, sz * (hw + 0.1 + ww * 0.5)),
				Vector3(SEG_LEN * 0.5, 0.3, ww * 0.5)))
		return d)

func meta() -> Dictionary:
	return {
		&"tag": "street",
		## 关键：路面不贴地，由布局层按地形逐段给 y
		&"surface_snap": false,
		&"wants_ground": true,
		## 沿 +X 延伸，横向法线朝 +Z：布局层按道路走向对齐
		&"face_dir": Vector3i(0, 0, 1),
	}
