@tool
class_name ShopGen
extends PropGen
## 街边小店 —— 独立单体生成器
##
## 只回答"一间店在自己的局部空间里长什么样"：墙体、雨棚、门窗凹槽，
## 尺寸由 seed 抖动。
## 它**不知道**自己在街道哪一侧、离邻店多远、朝哪 —— 那是 [PropLayoutTool] 的事。
##
## 正面朝局部 +Z（见 meta.face_dir），布局层会把它转向道路。

const HALF_W := 3.0   ## 店面半宽（米）
const WALL_H := 4.5   ## 檐口高度（米）

## 主体半深（米）。由 seed 在 [method prepare] 里定死。
var depth := 2.6

## 局部 +Z 为店面正前方。
func local_bounds() -> AABB:
	var d := depth + 0.6
	return AABB(
		Vector3(-HALF_W - 0.3, 0.0, -d),
		Vector3((HALF_W + 0.3) * 2.0, WALL_H + 0.3, d * 2.0 + 1.8))

## 避让只算墙体：雨棚是悬空的，把它算进去整条街会被撑得很稀疏。
func footprint() -> Vector2:
	return Vector2(HALF_W * 2.0, depth * 2.0)

func prepare() -> void:
	depth = 2.6 * rng.randf_range(0.88, 1.12)

func build(_field: SdfField) -> void:
	var w := HALF_W
	var h := WALL_H
	var dp := depth
	var win_x := w * 0.45   ## 窗心距中轴
	fill_shape(func(p: Vector3) -> float:
		# 主体
		var d := SdfTool.sd_box(p - Vector3(0, h * 0.5, 0), Vector3(w, h * 0.5, dp))
		# 雨棚：向 +Z 伸出的薄板，smin 融合出接缝的圆角
		d = SdfTool.op_smin(d, SdfTool.sd_box(
			p - Vector3(0, h * 0.7, dp + 0.6), Vector3(w, 0.12, 0.8)), 0.15)
		# 正面开两窗一门
		var cut := SdfTool.sd_box(
			p - Vector3(-win_x, h * 0.46, dp), Vector3(w * 0.28, h * 0.16, 0.4))
		cut = SdfTool.op_union(cut, SdfTool.sd_box(
			p - Vector3(win_x, h * 0.46, dp), Vector3(w * 0.28, h * 0.16, 0.4)))
		cut = SdfTool.op_union(cut, SdfTool.sd_box(
			p - Vector3(0, h * 0.24, dp), Vector3(w * 0.22, h * 0.24, 0.4)))
		return SdfTool.op_sub(d, cut))

func meta() -> Dictionary:
	return {
		&"tag": "shop",
		&"surface_snap": true,
		&"wants_ground": true,
		&"face_dir": Vector3i(0, 0, 1),
	}
