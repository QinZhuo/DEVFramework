@tool
class_name ModelSubtractNode extends ModelNode
## 差集 —— A 减 B（挖洞、开窗、掏膛）
##
## 什么时候用它而不是别的节点：
## · 从实体里挖掉东西：门窗洞、瓶口、钥匙孔、栅栏间隙；
## · 拼装时"贴上去"的东西用 union，"穿透进去"的东西用 subtract ——
##   这一条决定了成品有没有内部结构（union 出来的两段是实心的）；
## · **空端口语义**：`b` 悬空时 B 恒为 +1e9，`max(a, -1e9) = a`，
##   即"没接 B 就等于原样输出 A"。不需要任何 null 判断，也不会有人忘写判断。
##
## == 包围盒为什么取并集（偏大）==
## `A - B` 的真实包围盒是 `A ∩ B` 的几何结果，比 `A ∪ B` 小得多，
## 但**无法在不求值的前提下算准**：B 挖掉的是 A 的哪一块，要采样才知道。
## 取并集是安全的上界：多出来的只是空体素。若改取 `A ∩ B`（盒子求交），
## B 稍微超出 A 一点就会把盒子压成零尺寸 —— 那是**偏小**，会把壁面截出缺面。
## 这条"宁可偏大不可偏小"的取舍与 [method ModelNode.bounds_hint] 的注释同源。

func ports() -> Array[StringName]:
	var p: Array[StringName] = [&"a", &"b"]
	return p

## 光滑差集的过渡带宽度（米）。<= 0 走硬差 [method SdfTool.op_sub]。
var smooth: float = 0.0

var graph: ModelGraph = null

func bind_graph(g: ModelGraph) -> void:
	graph = g

#region 契约

func bounds_hint() -> AABB:
	return ModelNodeAccess.merge(
		ModelNodeAccess.input_bounds(self, &"a"),
		ModelNodeAccess.input_bounds(self, &"b"))

func shape(_rng: RandomNumberGenerator) -> Callable:
	var fa := ModelNodeAccess.input_shape(self, &"a")
	var fb := ModelNodeAccess.input_shape(self, &"b")
	if smooth <= 1e-6:
		return func(p: Vector3) -> float:
			return SdfTool.op_sub(fa.call(p), fb.call(p))
	var k := smooth
	return func(p: Vector3) -> float:
		return SdfTool.op_sub_smooth(fa.call(p), fb.call(p), k)

#endregion

#region 存档 / 调试

func params() -> Dictionary:
	return {"smooth": smooth}

func set_params(d: Dictionary) -> void:
	smooth = float(d.get("smooth", smooth))

func describe() -> String:
	return "差集%s" % ("(光滑%.2f)" % smooth if smooth > 1e-6 else "")

#endregion
