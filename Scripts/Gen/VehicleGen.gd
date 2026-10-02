@tool
class_name VehicleGen
extends PropGen
## 车辆 —— 独立单体生成器
##
## 与建筑类生成器的关键差异：
## 1. 精度要求高得多（体素 0.05m，见 [PropGenDef.voxel_size]），但体量小得多；
## 2. 局部空间**不以 y=0 起算** —— 车轮要落地，车身中心才在原点附近，
##    这样布局层贴地时用 MIN 模式最自然（车底最低点即轮底）；
## 3. 车头朝局部 +X（横向停放惯例），meta.face_dir 告知布局层。
##
## 车辆不该自己决定"停在哪条车道上"—— 那是布局层读道路数据的事。

const WHEEL_R := 0.34    ## 车轮半径（米）
const AXLE_X := 1.32     ## 前后轴距（半，+X 为车头）
const AXLE_Z := 0.78     ## 左右轮距（半）
const TRACK_W := 0.9     ## 车身半宽
const BODY_L := 2.1      ## 车身半长
const BODY_H := 0.72     ## 车身半高（自轮心起算）

var body_h := 0.72
var roof_h := 0.55
var cabin_l := 1.15      ## 座舱半长

func local_bounds() -> AABB:
	## y 从 0 起算：轮底贴地是布局层的事，这里只保证"最低点在 0 附近"。
	## 顶高必须按**座舱**算而不是车身 —— 座舱中心在 wr+1.85*bh，比车身顶高出一截，
	## 照车身算会截掉车顶（表现为车顶被削平，且只在 seed 较大时出现）。
	var top := WHEEL_R + body_h * 1.85 + roof_h
	return AABB(
		Vector3(-(BODY_L + 0.15), -0.15, -(TRACK_W + AXLE_Z + 0.1)),
		Vector3((BODY_L + 0.15) * 2.0, top + 0.45,
			(TRACK_W + AXLE_Z + 0.1) * 2.0))

func prepare() -> void:
	body_h = BODY_H * rng.randf_range(0.92, 1.1)
	roof_h = 0.55 * rng.randf_range(0.85, 1.15)
	cabin_l = cabin_l * rng.randf_range(0.9, 1.1)

func build(_field: SdfField) -> void:
	var bw := TRACK_W
	var bl := BODY_L
	var bh := body_h
	var rh := roof_h
	var cl := cabin_l
	var wr := WHEEL_R
	fill_shape(func(p: Vector3) -> float:
		# 下车身（圆角盒）
		var d := SdfTool.sd_round_box(
			p - Vector3(0, wr + bh, 0), Vector3(bl, bh, bw), 0.22)
		# 座舱：略窄的圆角盒，用 smin 融进车身
		d = SdfTool.op_smin(d, SdfTool.sd_round_box(
			p - Vector3(-0.15, wr + bh * 1.85, 0), Vector3(cl, rh, bw * 0.86), 0.2), 0.18)
		# 车轮：轴沿 X（sd_cylinder 的轴是 Y，故交换坐标）
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				var lp := p - Vector3(sx * AXLE_X, wr, sz * AXLE_Z)
				var wheel := SdfTool.sd_cylinder(Vector3(lp.z, lp.x, lp.y), 0.16, wr)
				# 轮拱：比车轮略大的圆柱，切出凹陷
				var arch := SdfTool.sd_cylinder(Vector3(lp.z, lp.x, lp.y), 0.2, wr + 0.12)
				d = SdfTool.op_smin(d, wheel, 0.06)
				d = SdfTool.op_sub(d, arch)
		return d)

func meta() -> Dictionary:
	return {
		&"tag": "vehicle",
		&"surface_snap": true,
		&"wants_ground": true,
		## 车头朝局部 +X：布局层按道路方向把它转过去
		&"face_dir": Vector3i(1, 0, 0),
	}
