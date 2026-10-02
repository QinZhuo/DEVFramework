@tool
class_name ShrineHallGen
extends PropGen
## 神社本殿（社殿）—— 参道尽头的大体量主体
##
## 和风建筑的辨识度集中在**屋顶**上：屋檐必须明显宽出墙体一大圈，
## 形成深深的水平阴影。把屋檐做成与墙体同宽，立刻变成普通方盒房子。
## 这里用大半径圆台顶近似瓦顶，并在屋脊上交叉一对**千木** ——
## 千木是神社建筑区别于寺庙与民宅的标志构件，微缩尺寸下尤其管用。
##
## 它**不知道**自己立在参道尽头还是别处 —— 那是 [PropLayoutTool] 的事。

const HALF := Vector3(2.40, 1.45, 1.55)   ## 主体半尺寸
const EAVE_R := 3.30                      ## 屋檐半径（明显宽出主体）
const BASE_H := 0.32                      ## 台阶高

var eave_r := EAVE_R       ## 屋檐半径（seed 抖动）
var has_chigi := true      ## 是否有千木

func local_bounds() -> AABB:
	var r := eave_r + 0.7
	return AABB(Vector3(-r, 0.0, -r * 0.8), Vector3(r * 2.0, 6.4, r * 1.6))

func footprint() -> Vector2:
	## 避让按**屋檐**算：微缩场景里屋檐就是实际占地，按墙体算会穿插。
	return Vector2(eave_r * 2.0, eave_r * 1.6)

func prepare() -> void:
	eave_r = EAVE_R * rng.randf_range(0.92, 1.08)
	has_chigi = rng.randf() < 0.85

func build(_field: SdfField) -> void:
	var h := HALF
	var body_y := BASE_H + h.y
	var roof_y := BASE_H + h.y * 2.0 + 0.70
	fill_shape(func(p: Vector3) -> float:
		# 台阶：压出"建在台基上"的稳重感，也让底部与地面有明确分界
		var d := SdfTool.sd_box(p - Vector3(0.0, BASE_H * 0.5, 0.0),
			Vector3(h.x + 0.35, BASE_H * 0.5, h.z + 0.35))
		# 主体
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, body_y, 0.0), h))
		# 屋顶：大半径圆台，底部宽（屋檐）顶部收，形成深阴影
		d = SdfTool.op_union(d, SdfTool.sd_capped_cone(
			p - Vector3(0.0, roof_y, 0.0), 0.75, eave_r, 0.45))
		# 前廊柱：正面一排细柱，和风立面的节奏感来源
		for sx in [-1.62, -0.54, 0.54, 1.62]:
			d = SdfTool.op_union(d, SdfTool.sd_cylinder(
				p - Vector3(sx, (BASE_H + h.y * 2.0) * 0.5 + BASE_H * 0.5, h.z + 0.22),
				(h.y * 2.0) * 0.5, 0.13))
		# 千木：屋脊上交叉的一对斜木，神社的标志
		if has_chigi:
			var yt := roof_y + 0.75
			d = SdfTool.op_union(d, SdfTool.sd_segment(p,
				Vector3(1.05, yt - 0.55, -0.55), Vector3(-0.35, yt + 1.05, 0.55), 0.10))
			d = SdfTool.op_union(d, SdfTool.sd_segment(p,
				Vector3(-1.05, yt - 0.55, -0.55), Vector3(0.35, yt + 1.05, 0.55), 0.10))
		return d)

func meta() -> Dictionary:
	return {
		&"tag": "shrinehall",
		&"surface_snap": true,
		&"wants_ground": true,
		&"face_dir": Vector3i(0, 0, 1),
	}
