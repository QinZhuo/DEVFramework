@tool
class_name ModelCapsuleNode extends ModelNode
## 胶囊（任意走向）—— 球扫掠一段线段
##
## 什么时候用它而不是别的节点：
## · 圆头肢体 / 手指 / 药丸：两端球头让 union 处天然无棱；
## · **斜**着的连杆（栏杆、斜撑、树枝）：给 `a` / `b` 两个任意端点即可，
##   不必"先沿 Y 造一个再用变换节点倾倒"—— 后者会让包围盒计算多绕一圈，
##   而且倾倒后的胶囊与竖直胶囊求并时圆头会错位；
## · 两端**平口**时用 `ModelCylinderNode`。
##
## 端点在 Y 轴铅垂线上（a.x == b.x 且 a.z == b.z）时转发 [method SdfTool.sd_capsule]
## —— 它比通用线段胶囊少一次投影，省一点每采样点开销；
## 其余走向转发 [method SdfTool.sd_segment]（线段 ⊕ 球：把 p 投到线段并夹到 [0,1]，
## 故端点外是球帽而不是锥）。
##
## 参数冗余是故意的：`height` 是"竖直胶囊"的便捷入口，`a`/`b` 全为零时
## 由它派生出 ±height/2 的对称端点。两者只生效其一，优先 a/b。

## 球半径（米）。
var radius: float = 0.2

## 便捷总高（米）。**仅在 a、b 均为原点时生效** —— 此时胶囊竖直、球心在 ±height/2。
var height: float = 1.0

## 下端球心（局部空间）。与 [member b] 同为零时改用 [member height] 派生。
var a: Vector3 = Vector3.ZERO

## 上端球心（局部空间）。任意走向的胶囊由它俩决定。
var b: Vector3 = Vector3.ZERO

#region 契约

func bounds_hint() -> AABB:
	var e := _endpoints()
	var pa: Vector3 = e[0]
	var pb: Vector3 = e[1]
	var r := absf(radius)
	## 线段的 AABB 就是两端各外扩 r：胶囊 = 线段 ⊕ 球，恰好抵到外接球冠。
	var mn := pa.min(pb) - Vector3.ONE * r
	var mx := pa.max(pb) + Vector3.ONE * r
	return AABB(mn, mx - mn)

func shape(_rng: RandomNumberGenerator) -> Callable:
	var r := absf(radius)
	var e := _endpoints()
	var pa: Vector3 = e[0]
	var pb: Vector3 = e[1]
	if is_equal_approx(pa.x, pb.x) and is_equal_approx(pa.z, pb.z):
		var half_h := absf(pb.y - pa.y) * 0.5
		var mid_y := (pa.y + pb.y) * 0.5
		return func(p: Vector3) -> float:
			return SdfTool.sd_capsule(p - Vector3(0, mid_y, 0), half_h, r)
	return func(p: Vector3) -> float:
		return SdfTool.sd_segment(p, pa, pb, r)

#endregion

#region 存档 / 调试

## 实际生效的两个端点（定长 2）：
## · 两端皆零 = "未指定" → 由 height 派生竖直对称胶囊；
## · 只有一端非零 → 另一端取原点（"从原点连到某点"这种最常见写法不必两处都填）；
## · 两端皆非零 → 原样使用，支持任意走向。
func _endpoints() -> Array[Vector3]:
	var flat_a := a.is_zero_approx()
	var flat_b := b.is_zero_approx()
	var out: Array[Vector3] = [a, b]
	if flat_a and flat_b:
		var hh := absf(height) * 0.5
		out[0] = Vector3(0.0, -hh, 0.0)
		out[1] = Vector3(0.0, hh, 0.0)
	elif flat_a:
		out[0] = Vector3.ZERO
	elif flat_b:
		out[1] = Vector3.ZERO
	return out

func params() -> Dictionary:
	return {"radius": radius, "height": height, "a": a, "b": b}

func set_params(d: Dictionary) -> void:
	radius = float(d.get("radius", radius))
	height = float(d.get("height", height))
	a = d.get("a", a)
	b = d.get("b", b)

func describe() -> String:
	return "胶囊(r=%.2f)" % radius

#endregion
