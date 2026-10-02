@tool
class_name HospitalGen
extends PropGen
## 医院 —— 独立单体生成器
##
## 与 [ShopGen] 完全平级：同样只管自己的局部几何，**不因为"更大更重要"就
## 获得任何世界信息**。体量差异只体现在 [method local_bounds] 的数字上。
##
## 形体：两层主体 + 二层退台 + 入口门廊 + 墙面医疗十字。

const HALF_W := 7.0    ## 半宽（米）
const HALF_D := 5.5    ## 半深（米）
const FLOOR_H := 4.2   ## 层高（米）
const FLOORS := 2      ## 层数

## 二层退台的缩放与高度（由 seed 微调）
var upper_scale := 0.78
var total_h := 9.6

func local_bounds() -> AABB:
	return AABB(
		Vector3(-HALF_W - 0.4, 0.0, -HALF_D - 0.4),
		Vector3((HALF_W + 0.4) * 2.0, total_h + 0.5, (HALF_D + 0.4) * 2.0 + 1.0))

func prepare() -> void:
	upper_scale = rng.randf_range(0.72, 0.86)
	total_h = FLOOR_H * FLOORS + rng.randf_range(-0.3, 0.7)

func build(_field: SdfField) -> void:
	var w := HALF_W
	var dp := HALF_D
	var fh := FLOOR_H
	var us := upper_scale
	var th := total_h
	fill_shape(func(p: Vector3) -> float:
		# 一层：整块
		var d := SdfTool.sd_box(p - Vector3(0, fh * 0.5, 0), Vector3(w, fh * 0.5, dp))
		# 二层：退台（收窄），与一层交接处用 smin 稍作圆化
		var up := SdfTool.sd_box(
			p - Vector3(0, fh + (th - fh) * 0.5, 0),
			Vector3(w * us, (th - fh) * 0.5, dp * us))
		d = SdfTool.op_smin(d, up, 0.25)
		# 入口门廊：两柱一顶，向 +Z 伸出
		for sx in [-1.0, 1.0]:
			d = SdfTool.op_smin(d, SdfTool.sd_box(
				p - Vector3(sx * 2.2, 1.6, dp + 0.7), Vector3(0.35, 1.6, 0.7)), 0.12)
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0, 3.4, dp + 0.7), Vector3(2.9, 0.22, 0.9)))
		# 墙面医疗十字：贴在 +Z 正面，凸出墙体
		var cross := SdfTool.sd_box(p - Vector3(0, fh * 1.5, dp), Vector3(0.28, 1.1, 0.12))
		cross = SdfTool.op_union(cross, SdfTool.sd_box(
			p - Vector3(0, fh * 1.5, dp), Vector3(1.1, 0.28, 0.12)))
		d = SdfTool.op_union(d, cross)
		return d)

func meta() -> Dictionary:
	return {
		&"tag": "hospital",
		&"surface_snap": true,
		&"wants_ground": true,
		&"face_dir": Vector3i(0, 0, 1),
	}
