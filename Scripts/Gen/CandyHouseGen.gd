@tool
class_name CandyHouseGen
extends PropGen
## 童话糖果屋 —— 微缩模型向单体
##
## 与和风那套相反，这里的画法刻意**处处圆润**：
## · 主体用 [method SdfTool.sd_round_box] 而非方盒，墙角带倒圆才像捏出来的糖；
## · 部件之间用 [method SdfTool.op_smin] 而非硬 union，接缝要融而不是拼；
## · 屋顶是圆锥 + 一圈糖霜环，尖顶配宽檐是"可收藏模型"的经典剪影。
##
## 细节密度刻意压低：微缩模型的精致感来自**剪影清楚 + 部件少**，
## 堆太多小装饰反而变成噪声，在三渲二下还会互相糊成一团。
##
## 它**不知道**自己摆在哪块台座上 —— 那是 [PropLayoutTool] 的事。

const BODY_HALF := Vector3(1.35, 1.05, 1.20)
const ROOF_R := 1.85      ## 屋檐半径
const ROOF_H := 1.05      ## 屋顶半高

var pop := true           ## 门口是否插棒棒糖（seed 抖动）
var icing := true         ## 屋檐是否挂糖霜环
var roof_scale := 1.0

func local_bounds() -> AABB:
	var r := ROOF_R * roof_scale
	var top := 3.15 + ROOF_H * roof_scale
	return AABB(Vector3(-r - 0.8, 0.0, -r - 0.8),
		Vector3((r + 0.8) * 2.0, top + 0.6, (r + 0.8) * 2.0))

func footprint() -> Vector2:
	## 避让按屋檐直径算 —— 微缩场景里屋檐就是实际占地，躲太近会穿插。
	return Vector2(ROOF_R * roof_scale * 2.0, ROOF_R * roof_scale * 2.0)

func prepare() -> void:
	pop = rng.randf() < 0.75
	icing = rng.randf() < 0.7
	roof_scale = rng.randf_range(0.9, 1.12)

func build(_field: SdfField) -> void:
	var bh := BODY_HALF
	var rs := roof_scale
	var body_top := bh.y * 2.0
	var roof_y := body_top + ROOF_H * rs - 0.15
	fill_shape(func(p: Vector3) -> float:
		# 主体：圆角盒，倒圆半径不小 —— 糖块的钝感全靠它
		var d := SdfTool.sd_round_box(
			p - Vector3(0.0, bh.y, 0.0), bh, 0.16)

		# 屋顶：圆锥，smin 与主体融合出"糖霜堆叠"的软接缝
		var roof := SdfTool.sd_capped_cone(
			p - Vector3(0.0, roof_y, 0.0), ROOF_H * rs, ROOF_R * rs, 0.06)
		d = SdfTool.op_smin(d, roof, 0.18)

		# 门：方洞 + 上方半圆拱，拱用一根竖胶囊抠出圆角顶
		var door := SdfTool.sd_box(
			p - Vector3(0.0, 0.46, bh.z), Vector3(0.32, 0.46, 0.30))
		door = SdfTool.op_smin(door, SdfTool.sd_cylinder(
			p - Vector3(0.0, 0.92, bh.z), 0.10, 0.32), 0.12)
		# 窗：左右各一，圆角方洞
		var cut := door
		for sx in [-0.72, 0.72]:
			cut = SdfTool.op_union(cut, SdfTool.sd_round_box(
				p - Vector3(sx, 1.42, bh.z), Vector3(0.26, 0.26, 0.30), 0.12))
		d = SdfTool.op_sub(d, cut)

		# 糖霜环：沿屋檐一圈，让屋顶与主体的交界有个"挤出来"的装饰边
		if icing:
			d = SdfTool.op_smin(d, SdfTool.sd_torus(
				p - Vector3(0.0, body_top - 0.10, 0.0), ROOF_R * rs * 0.94, 0.11), 0.10)

		# 棒棒糖：门口两侧各一根，竿用细柱、头用球
		if pop:
			for sx in [-1.55, 1.55]:
				var stick := SdfTool.sd_cylinder(
					p - Vector3(sx, 0.55, bh.z + 0.35), 0.55, 0.05)
				var head := SdfTool.sd_sphere(
					p - Vector3(sx, 1.24, bh.z + 0.35), 0.24)
				d = SdfTool.op_union(d, SdfTool.op_union(stick, head))
		return d)

func meta() -> Dictionary:
	return {
		&"tag": "candyhouse",
		&"surface_snap": true,
		&"wants_ground": true,
		&"face_dir": Vector3i(0, 0, 1),
	}
