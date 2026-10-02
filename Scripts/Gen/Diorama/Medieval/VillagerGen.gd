@tool
class_name VillagerGen
extends PropGen
## 用例二道具 —— 低模村民：三级收分的身体 + 方头 + 可选尖帽
##
## ## 为什么身体是"三级收分"而不是胶囊
## 1.7 米的人、0.14 米的体素 ⇒ 全身只有 **12 格高**。这个尺度下任何曲面
##    （胶囊、球头）都只会变成一团圆的疙瘩，看不出是人还是石头。
##    三级方盒（下摆 → 上身 → 肩）能在 12 格里给出"上窄下宽"的人形剪影。
## 2. 头是**方**的：真球头在 12 格尺度下与身体连成一根柱子，
##    而方头比肩窄 0.1 米，侧面能读出脖子那道凹 —— 那是"这是个人"的关键。
##
## ## 随机什么、不随机什么
## [method prepare] 里只随机**衣色与戴不戴帽**（两种衣色、两种帽），
## 身高与体型一律固定：村民间体型不一致时，relax 避让会因为外接半径忽大忽小
## 而把两个人挤到互相重叠 —— 那才是真出问题（见 [DioramaPresets] 的避让说明）。

const HIP_W := 0.26    ## 下摆半宽
const HIP_H := 0.62
const TORSO_W := 0.23  ## 上身半宽
const TORSO_H := 0.48
const SHOULD_W := 0.28 ## 肩半宽（比上身宽 ⇒ 有肩）
const SHOULD_H := 0.16
const HEAD_W := 0.13   ## 头半宽
const HEAD_H := 0.30
const HAT_H := 0.26    ## 尖帽高（阶梯三级）

var cloth := MedievalSkin.CLOTH_A
var hat := true

func prepare() -> void:
	cloth = MedievalSkin.CLOTH_A if rng.randi_range(0, 1) == 0 else MedievalSkin.CLOTH_B
	hat = rng.randi_range(0, 2) != 0

func local_bounds() -> AABB:
	var h := HIP_H + TORSO_H + SHOULD_H + HEAD_H + HAT_H
	return AABB(Vector3(-0.32, 0.0, -0.32), Vector3(0.64, h, 0.64))

func build(_field: SdfField) -> void:
	var c := cloth
	var has_hat := hat
	fill_shape(func(p: Vector3) -> float:
		var d := 1e9
		var y := 0.0
		## 下摆（裙/裤）
		d = SdfTool.sd_box(p - Vector3(0.0, HIP_H * 0.5, 0.0),
			Vector3(HIP_W, HIP_H * 0.5, HIP_W * 0.78))
		y = HIP_H
		## 上身
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, y + TORSO_H * 0.5, 0.0),
			Vector3(TORSO_W, TORSO_H * 0.5, TORSO_W * 0.80)))
		y += TORSO_H
		## 肩：比上身宽，与上身之间那道错台就是衣领
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, y + SHOULD_H * 0.5, 0.0),
			Vector3(SHOULD_W, SHOULD_H * 0.5, SHOULD_W * 0.72)))
		y += SHOULD_H
		## 脖子：一小段比头窄的柱，让头能"读出来"
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, y + 0.05, 0.0), Vector3(0.07, 0.05, 0.07)))
		y += 0.08
		## 头
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, y + HEAD_H * 0.5, 0.0),
			Vector3(HEAD_W, HEAD_H * 0.5, HEAD_W)))
		## 两侧垂手：两个细柱 —— **不垂手的话，12 格的人形读不出肩宽**
		for sx in [-0.30, 0.30]:
			d = SdfTool.op_union(d, SdfTool.sd_box(
				p - Vector3(sx, 0.78, 0.0), Vector3(0.07, 0.34, 0.07)))
		if has_hat:
			## 尖帽：三级阶梯，每级收 0.05
			var hy := y + HEAD_H
			var hw := HEAD_W + 0.06
			for i in 3:
				d = SdfTool.op_union(d, SdfTool.sd_box(
					p - Vector3(0.0, hy + 0.07, 0.0), Vector3(hw, 0.07, hw)))
				hy += 0.14
				hw = maxf(hw - 0.05, 0.05)
		return d)

func voxel_regions() -> Array:
	var b := local_bounds()
	var y_head := HIP_H + TORSO_H + SHOULD_H + 0.08
	var out := []
	## ① 头与手：肤色
	out.append(MedievalSkin.box(Vector3(0.0, y_head + HEAD_H * 0.5, 0.0),
		Vector3(HEAD_W * 2.0, HEAD_H, HEAD_W * 2.0), MedievalSkin.SKIN))
	for sx in [-0.30, 0.30]:
		out.append(MedievalSkin.box(Vector3(sx, 0.78, 0.0),
			Vector3(0.14, 0.68, 0.14), MedievalSkin.SKIN))
	## ② 帽子（若戴）：赭红，压住头部
	if hat:
		out.append(MedievalSkin.box(Vector3(0.0, y_head + HEAD_H + 0.21, 0.0),
			Vector3(0.42, 0.46, 0.42), MedievalSkin.CLOTH_A))
	## ③ 兜底：衣色（本次随机出来的那一种）
	out.append(MedievalSkin.all(b, cloth))
	return out

func meta() -> Dictionary:
	return {
		&"tag": "villager",
		&"surface_snap": true,
		&"wants_ground": true,
		&"face_dir": Vector3i(0, 0, 1),
	}
