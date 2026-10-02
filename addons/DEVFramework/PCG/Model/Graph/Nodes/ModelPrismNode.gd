@tool
class_name ModelPrismNode extends ModelNode
## 正 n 边形棱柱（可倒角）—— 六角柱、八角柱、楔形块
##
## 什么时候用它而不是别的节点：
## · 柱子的"棱数"是风格线索：六角=东方古建、八角=粗木、十二角=机械 ——
##   用盒 + 硬边化只能得到 4 棱轮廓，对不上；
## · 楔形 / 三角柱做屋顶、楔子、箭头基座；
## · **不适合**大边数：面 SDF 按 [member sides] 逐边迭代，sides 每 +2 采样成本涨一截，
##   且面数远超体素分辨率时棱柱与"圆角盒 + 硬边化"在成品里看不出差别。
##
## 面 SDF 转发 [method SdfTool.sd_prism]（内部调 [method SdfTool.sd_ngon] 取
## XZ 正 n 边形轮廓，再与 Y 区间组合）。基座负责 `maxi(n, 3)` 兜底，
## 本节点仍先夹一次 —— 参数存的是存档里的手滑数字，不该进 SDF 计算。
## 倒角同样用"内收 k 再外扩 k"，故包围盒不随 `round` 变化。

## 外接半径（XZ）与半高（Y），米。[member sides] 为 3 时即三角柱/楔子。
var half_extent: Vector2 = Vector2(0.4, 0.6)

## 边数。3 起；< 3 时按 3 处理（退化形状没有意义）。
var sides: int = 6

## 倒角半径（米），向内收，占据范围不变（与圆角盒同理）。
var round: float = 0.0

#region 契约

func bounds_hint() -> AABB:
	var r := absf(half_extent.x)
	var h := absf(half_extent.y)
	return AABB(Vector3(-r, -h, -r), Vector3(r * 2.0, h * 2.0, r * 2.0))

func shape(_rng: RandomNumberGenerator) -> Callable:
	var n: int = maxi(sides, 3)
	var r := absf(half_extent.x)
	var h := absf(half_extent.y)
	var k := 0.0
	if round > 1e-5:
		k = minf(round, minf(r, h))
		r = maxf(r - k, 0.0)
		h = maxf(h - k, 0.0)
	if k > 0.0:
		return func(p: Vector3) -> float:
			return SdfTool.sd_prism(p, r, h, n) - k
	return func(p: Vector3) -> float:
		return SdfTool.sd_prism(p, r, h, n)

#endregion

#region 存档 / 调试

func params() -> Dictionary:
	return {"half_extent": half_extent, "sides": sides, "round": round}

func set_params(d: Dictionary) -> void:
	half_extent = d.get("half_extent", half_extent)
	sides = int(d.get("sides", sides))
	round = float(d.get("round", round))

func describe() -> String:
	return "%d棱柱(R=%.2f h=%.2f)" % [maxi(sides, 3), half_extent.x, half_extent.y]

#endregion
