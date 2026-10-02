@tool
class_name ToriiGen
extends PropGen
## 和风鸟居 —— 神社场景的标志单体
##
## 结构按真实鸟居的**五个部件**搭：立柱 ×2 / 笠木（顶梁）/ 岛木（次梁）/ 贯（下横梁）/ 额束。
## 少了笠木与岛木这两道叠梁，鸟居会立刻退化成"两根柱子架一根横梁"的门框，
## 失去辨识度 —— 微缩模型恰恰靠这种部件层次才显得精制。
##
## 只回答"一座鸟居在自己局部空间里长什么样"。
## 它**不知道**自己立在参道哪一段、朝向哪 —— 那是 [PropLayoutTool] 的事。
##
## 正面（可穿过的方向）朝局部 ±Z，见 meta.face_dir。

const H := 6.0            ## 立柱高（米）
const HALF_SPAN := 2.2    ## 柱心半距（地面处）
const PILLAR_R := 0.26    ## 柱半径

## 柱顶内倾量（米）。鸟居的柱不是铅垂的，而是**向内微倾**（"転び"），
## 这是它区别于普通门框的关键姿态，由 seed 抖动。
var lean := 0.18

## 横梁两端挑出柱外的长度（米）。挑檐越长越有神社的庄重感。
var beam_over := 0.9

func local_bounds() -> AABB:
	## X 要盖住笠木 + 挑出，Y 要盖住笠木顶面，Z 只需薄薄一层（鸟居是片状的）。
	return AABB(Vector3(-3.7, 0.0, -1.0), Vector3(7.4, H + 0.9, 2.0))

## 避让只算柱脚占地 —— 笠木挑在柱外，算进去整条参道会被撑得很稀疏。
func footprint() -> Vector2:
	return Vector2(HALF_SPAN * 2.0 + 0.7, 0.9)

func prepare() -> void:
	lean = 0.16 * rng.randf_range(0.7, 1.35)
	beam_over = 0.9 * rng.randf_range(0.88, 1.12)

func build(_field: SdfField) -> void:
	var span := HALF_SPAN
	var top_x := span - lean
	var ov := beam_over
	fill_shape(func(p: Vector3) -> float:
		# 两根内倾立柱：用 segment 而非 cylinder，因为铅垂柱做不出"転び"
		var d := SdfTool.sd_segment(p,
			Vector3(-span, 0.0, 0.0), Vector3(-top_x, H, 0.0), PILLAR_R)
		d = SdfTool.op_union(d, SdfTool.sd_segment(p,
			Vector3(span, 0.0, 0.0), Vector3(top_x, H, 0.0), PILLAR_R))

		# 笠木（顶梁）：最上一道，挑出最长
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, H + 0.10, 0.0), Vector3(span + ov, 0.15, 0.34)))
		# 岛木：紧贴笠木下方的第二道，略短 —— 两道叠梁是鸟居的辨识核心
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, H - 0.30, 0.0), Vector3(span + ov * 0.70, 0.12, 0.28)))
		# 贯：下部横梁，穿过立柱（不挑出）
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, H * 0.64, 0.0), Vector3(span - 0.06, 0.11, 0.22)))
		# 额束：笠木与贯之间居中的短柱，挂匾额的位置
		d = SdfTool.op_union(d, SdfTool.sd_box(
			p - Vector3(0.0, H * 0.86, 0.0), Vector3(0.17, 0.50, 0.17)))
		return d)

func meta() -> Dictionary:
	return {
		&"tag": "torii",
		&"surface_snap": true,
		&"wants_ground": true,
		&"face_dir": Vector3i(0, 0, 1),
	}
