@tool
class_name LanternGen
extends PropGen
## 和风石灯笼 —— 参道两侧的配景单体
##
## 自下而上六段：基座 / 竿（柱身）/ 中台 / 火袋（灯室）/ 笠（伞盖）/ 宝珠。
## 石灯笼的辨识度几乎全在**比例**上：火袋要矮胖、笠要宽出火袋一大圈，
## 这两处一改就像路灯而不像灯笼了。
##
## 火袋四面开窗（十字贯通），让内部在逆光下透出暖色 —— 这是和风夜景的氛围来源。
##
## 它**不知道**自己摆在哪一侧、离鸟居多远 —— 那是 [PropLayoutTool] 的事。

var scale_h := 1.0    ## 整体高度系数（seed 抖动）
var cap_r := 0.78     ## 笠（伞盖）半径

func local_bounds() -> AABB:
	var h := _total_h()
	return AABB(Vector3(-1.1 * scale_h, 0.0, -1.1 * scale_h),
		Vector3(2.2 * scale_h, h + 0.5, 2.2 * scale_h))

func footprint() -> Vector2:
	return Vector2(cap_r * 2.0 * scale_h, cap_r * 2.0 * scale_h)

func prepare() -> void:
	scale_h = rng.randf_range(0.86, 1.14)
	cap_r = 0.78 * rng.randf_range(0.92, 1.08)

func build(_field: SdfField) -> void:
	var s := scale_h
	var base_y := 0.35 * s          ## 基座中心
	var pole_y := 1.62 * s          ## 竿中心
	var mid_y := 2.62 * s           ## 中台中心
	var box_y := 3.10 * s           ## 火袋中心
	var cap_y := 3.72 * s           ## 笠中心
	var ball_y := 4.12 * s          ## 宝珠中心
	fill_shape(func(p: Vector3) -> float:
		# 基座：上小下大的圆台，压住视觉重心
		var d := SdfTool.sd_capped_cone(
			p - Vector3(0.0, base_y, 0.0), 0.35 * s, 0.55 * s, 0.42 * s)
		# 竿：细柱身，长于其余各段之和的一半 —— 灯笼"瘦高"的关键
		d = SdfTool.op_union(d, SdfTool.sd_cylinder(
			p - Vector3(0.0, pole_y, 0.0), 0.92 * s, 0.15 * s))
		# 中台：承上启下的薄盘
		d = SdfTool.op_union(d, SdfTool.sd_cylinder(
			p - Vector3(0.0, mid_y, 0.0), 0.12 * s, 0.40 * s))
		# 火袋：矮胖方箱，四面开窗
		var box := SdfTool.sd_box(
			p - Vector3(0.0, box_y, 0.0), Vector3(0.34, 0.34, 0.34) * s)
		# 十字贯通的窗洞：X 向一条 + Z 向一条，四面都透光
		var cut := SdfTool.sd_box(
			p - Vector3(0.0, box_y, 0.0), Vector3(0.52, 0.17, 0.15) * s)
		cut = SdfTool.op_union(cut, SdfTool.sd_box(
			p - Vector3(0.0, box_y, 0.0), Vector3(0.15, 0.17, 0.52) * s))
		d = SdfTool.op_union(d, SdfTool.op_sub(box, cut))
		# 笠：伞盖，明显宽出火袋
		d = SdfTool.op_union(d, SdfTool.sd_capped_cone(
			p - Vector3(0.0, cap_y, 0.0), 0.24 * s, cap_r, 0.10 * s))
		# 宝珠：顶上那颗小球
		d = SdfTool.op_union(d, SdfTool.sd_sphere(
			p - Vector3(0.0, ball_y, 0.0), 0.17 * s))
		return d)

func meta() -> Dictionary:
	return {
		&"tag": "lantern",
		&"surface_snap": true,
		&"wants_ground": true,
		&"face_dir": Vector3i(0, 0, 1),
	}

## 总高（米），供 [method local_bounds] 与布局层估算。
func _total_h() -> float:
	return 4.30 * scale_h
