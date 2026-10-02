@tool
class_name ModelCylinderNode extends ModelNode
## 圆柱 / 圆台（可倒角）—— 腿、柱、桶、锥形塔
##
## 什么时候用它而不是别的节点：
## · 腿 / 柱 / 桅杆：`taper = 1`（纯圆柱），零额外成本；
## · 圆台（`taper < 1`，如塔尖、削顶的柱子）：SDF 里圆柱与圆台是同一族函数，
##   差别只在顶部半径，因此**同一个节点**能覆盖，不必写两个类；
## · 圆头端面请用 `ModelCapsuleNode`（半球头）或 `round > 0`（平面倒角）——
##   倒角只削一道边，不做球冠。
##
## `taper == 1` 时转发 [method SdfTool.sd_cylinder]（它就是 `r1 == r2` 的圆台）；
## 否则转发 [method SdfTool.sd_capped_cone]。
## 倒角用"半径与半高各内收 k、结果再外扩 k"实现 —— 与圆角盒同一套做法，
## 占据范围不变，故包围盒不随 `round` 变化。
## 公式只在基座存一份：同一段 SDF 写两遍必然漂移（改一处忘另一处，
## 症状是"某个节点和某个算子的结果对不上"，极难定位）。
##
## 坐标约定：**所有基元以自身原点为中心**，不像 PropGen 那样 y 从 0 起算 ——
## 因为节点图里的基元要被 union/差集来组合，中心对齐才叠得准；
## 整图落地（贴地）由 [PropLayoutTool] 或外层 `ModelTransformNode` 负责。

## 底部半径（米）。`taper < 1` 时这是**下端**半径，上端为 `radius * taper`。
var radius: float = 0.3

## 总高（米，不是半高）。基元以原点为中心，故占据 y ∈ [-height/2, +height/2]。
var height: float = 1.0

## 倒角半径（米）。同时削上下端面与侧棱；0 = 硬边（靠 `ModelHardenNode` 做棱面）。
var round: float = 0.0

## 顶部半径比例。1 = 圆柱，0.5 = 上小下大的圆台，<= 0 退化为锥尖。
var taper: float = 1.0

#region 契约

func bounds_hint() -> AABB:
	var r := absf(radius)
	var h := absf(height) * 0.5
	## 底部半径恒为 radius（上端只会更小），故 XZ 半宽取 radius 即为紧包围盒；
	## 倒角是"向内收"，不改变占据范围。
	return AABB(Vector3(-r, -h, -r), Vector3(r * 2.0, h * 2.0, r * 2.0))

func shape(_rng: RandomNumberGenerator) -> Callable:
	var r := absf(radius)
	var h := absf(height) * 0.5
	var tp := maxf(taper, 0.0)
	## 倒角向内收：半径与半高各减 k 后再外扩 k，占据范围不变 —— 与圆角盒同理。
	var k := 0.0
	if round > 1e-5:
		k = minf(round, minf(r, h))
	r = maxf(r - k, 0.0)
	h = maxf(h - k, 0.0)
	if tp >= 0.999:
		if k > 0.0:
			return func(p: Vector3) -> float:
				return SdfTool.sd_cylinder(p, h, r) - k
		return func(p: Vector3) -> float:
			return SdfTool.sd_cylinder(p, h, r)
	var rt := r * tp
	if k > 0.0:
		return func(p: Vector3) -> float:
			return SdfTool.sd_capped_cone(p, h, maxf(r - k, 0.0), maxf(rt - k, 0.0)) - k
	return func(p: Vector3) -> float:
		return SdfTool.sd_capped_cone(p, h, r, rt)

#endregion

#region 存档 / 调试

func params() -> Dictionary:
	return {"radius": radius, "height": height, "round": round, "taper": taper}

func set_params(d: Dictionary) -> void:
	radius = float(d.get("radius", radius))
	height = float(d.get("height", height))
	round = float(d.get("round", round))
	taper = float(d.get("taper", taper))

func describe() -> String:
	var kind := "圆柱" if taper >= 0.999 else "圆台"
	return "%s(r=%.2f h=%.2f%s)" % [kind, radius, height, ", 倒角%.2f" % round if round > 0.0 else ""]

#endregion
