@tool
class_name ModelUnionNode extends ModelNode
## 并集 —— 把两段形状黏成一个
##
## 什么时候用它而不是别的节点：
## · 拼装（桌腿 + 桌面）、补缺口（union 一个球把凹陷填圆）；
## · **倒角技巧**：`smooth` > 0 时 union 会在两段之间生成一段过渡曲面，
##   这是 SDF 最便宜的"圆角"手段 —— 比给每个基元单独算圆角省一个节点；
## · 不要用它做"材质分区"（那是 [ModelSlotNode] 的活）——
##   union 只是几何合并，颜色信息不会因此产生。
##
## == smooth 的量级 ==
## `smooth` 是过渡带宽度（米），不是"百分比"：0.05 在 2 m 的物体上刚好，
## 0.3 会把两个柱子的接缝糊成一团。默认 0 = 硬并（min），行为可预测。

## 输入端口。顺序即声明顺序，未连接者取 [method ModelNode.null_shape]。
func ports() -> Array[StringName]:
	var p: Array[StringName] = [&"a", &"b"]
	return p

## 过渡带宽度（米）。<= 0 走硬并 [method SdfTool.op_union]。
var smooth: float = 0.0

var graph: ModelGraph = null

func bind_graph(g: ModelGraph) -> void:
	graph = g

#region 契约

func bounds_hint() -> AABB:
	## 并集 = 两者的并集。这里也正是"空盒子当单位元"必须成立的原因：
	## 少接一根线时 merge 会跳过它，于是单输入的用法天然合法。
	return ModelNodeAccess.merge(
		ModelNodeAccess.input_bounds(self, &"a"),
		ModelNodeAccess.input_bounds(self, &"b"))

func shape(_rng: RandomNumberGenerator) -> Callable:
	var fa := ModelNodeAccess.input_shape(self, &"a")
	var fb := ModelNodeAccess.input_shape(self, &"b")
	if smooth <= 1e-6:
		return func(p: Vector3) -> float:
			return SdfTool.op_union(fa.call(p), fb.call(p))
	var k := smooth
	return func(p: Vector3) -> float:
		return SdfTool.op_smin(fa.call(p), fb.call(p), k)

#endregion

#region 存档 / 调试

func params() -> Dictionary:
	return {"smooth": smooth}

func set_params(d: Dictionary) -> void:
	smooth = float(d.get("smooth", smooth))

func describe() -> String:
	return "并集%s" % ("(融合%.2f)" % smooth if smooth > 1e-6 else "")

#endregion
