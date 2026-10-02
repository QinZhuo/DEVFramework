@tool
class_name ModelBoxNode extends ModelNode
## 盒（可圆角）—— 三渲二硬边块体的基本形
##
## 什么时候用它而不是别的节点：
## · 板、墙、台阶、底座 —— 直角是绝大多数"人造物"的默认形状；
## · `round > 0` 时它就是**圆角盒**，比"盒 + union 球"便宜得多（一次调用 vs 两次）；
## · 真正的硬边棱柱请交给 `ModelHardenNode`（画风开关），不要用零半径盒去凑 ——
##   硬边化是**整场量化**，能把任何光滑曲面变成棱面，盒只是它的输入之一。
##
## `round > 0` 走 [method SdfTool.sd_round_box]，否则 [method SdfTool.sd_box]：
## 两者都是本节点的转发，不本地重写。
## 注意 sd_round_box 的半长是 `half - round` 再外扩 `round`，**实际占据恰好 ±half**，
## 所以包围盒不随 round 变化 —— 这是最容易搞错的一点（错在这里会凭空多一圈体素）。

## 半长（米，三轴各自到表面的距离）。
var half: Vector3 = Vector3(0.5, 0.5, 0.5)

## 圆角半径（米）。0 = 硬边盒。上限自动收敛到 [member half] 的最小值。
var round: float = 0.0

#region 契约

func bounds_hint() -> AABB:
	var h := half.abs()
	return AABB(-h, h * 2.0)

func shape(_rng: RandomNumberGenerator) -> Callable:
	var h := half.abs()
	if round > 1e-5:
		## 圆角不得吃掉整个盒子：sd_round_box 内部是 max(half - r, 0) - r，
		## r >= half 时盒会塌成一个球心点，这里提前收敛避免退化形状。
		var r := minf(round, minf(h.x, minf(h.y, h.z)))
		return func(p: Vector3) -> float:
			return SdfTool.sd_round_box(p, h, r)
	return func(p: Vector3) -> float:
		return SdfTool.sd_box(p, h)

#endregion

#region 存档 / 调试

func params() -> Dictionary:
	return {"half": half, "round": round}

func set_params(d: Dictionary) -> void:
	half = d.get("half", half)
	round = float(d.get("round", round))

func describe() -> String:
	return "盒(%.2f×%.2f×%.2f%s)" % [half.x, half.y, half.z, ", 圆角%.2f" % round if round > 0.0 else ""]

#endregion
