@tool
class_name ModelIntersectNode extends ModelNode
## 交集 —— 只保留两者都覆盖的部分（切料、裁剪）
##
## 什么时候用它而不是别的节点：
## · **切料**：`盒 ∩ 球` 得到球冠、`盒 ∩ 板` 得到一块平整的料；
## · 限制子图范围："这段子树不许越过这条线" —— 用 `大盒 ∩ 子图` 比事后
##   拿场去裁要省一整块体素；
## · 端口顺序无所谓（max 可交换），但为了存档可读仍固定 a、b。
##
## 形状用 [method SdfTool.op_intersect]（max），不设 smooth：
## 光滑交集（smax）在 SDF 里很容易做出**反向凹陷**（过渡带往内凹），
## 真要圆滑过渡应当用 union 的 smooth 或 [ModelShellNode]，不要在这里凑。

func ports() -> Array[StringName]:
	var p: Array[StringName] = [&"a", &"b"]
	return p

var graph: ModelGraph = null

func bind_graph(g: ModelGraph) -> void:
	graph = g

#region 契约

func bounds_hint() -> AABB:
	## 取**并集**而非盒子求交：交集的真实范围在不求值时算不准，
	## 而"盒子求交"很容易退化成零尺寸（两段刚好各错开一点），
	## 偏小的包围盒会把切面截掉一整圈 —— 表现为切面上出现缺面。
	## 差集节点是同一条理由。
	return ModelNodeAccess.merge(
		ModelNodeAccess.input_bounds(self, &"a"),
		ModelNodeAccess.input_bounds(self, &"b"))

func shape(_rng: RandomNumberGenerator) -> Callable:
	var fa := ModelNodeAccess.input_shape(self, &"a")
	var fb := ModelNodeAccess.input_shape(self, &"b")
	return func(p: Vector3) -> float:
		return SdfTool.op_intersect(fa.call(p), fb.call(p))

#endregion

#region 存档 / 调试

func params() -> Dictionary:
	return {}

func describe() -> String:
	return "交集"

#endregion
