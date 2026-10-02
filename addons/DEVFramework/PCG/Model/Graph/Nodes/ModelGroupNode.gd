@tool
class_name ModelGroupNode extends ModelNode
## 语义分组 —— 给一段子图起名字
##
## 解决什么问题：一张节点图超过十几个节点之后，"哪几根线属于屋顶"只有画图的人知道。
## 本节点在图里插一个**纯标记**：形状与包围盒完全透传，
## 但 [method describe] / [method params] 里会出现 [member group] 的名字，
## 于是存档可读、调试日志可读、编辑器折叠可读 —— 而结构本身零成本。
##
## 什么时候用它：
## · 存档要能被人读懂（"桌腿组 / 桌面组"比一串 `n17` 有用得多）；
## · 调试时需要把一段子图当成一个整体来看；
## · 想给子图预留命名空间，将来整体换风格（换参数集）时按组遍历。
##
## 什么时候**不要**用：
## · 想做材质分区 —— 那是 [ModelSlotNode] 的活，本节点不产生任何槽位；
## · 想做布尔分组 —— 布尔会改变形状，本节点不会。

## 组名。会出现在 describe() 与存档 params 里。留空则本节点退化为纯透传。
var group: String = ""

var graph: ModelGraph = null

func bind_graph(g: ModelGraph) -> void:
	graph = g

#region 契约

func bounds_hint() -> AABB:
	## 透传：分组不改变任何几何，包围盒必须原样交给下游（偏大偏小都会传导下去）。
	return ModelNodeAccess.input_bounds(self, &"in")

func shape(_rng: RandomNumberGenerator) -> Callable:
	## 直接把上游的 Callable 原样返回，连一次包装都不加 ——
	## 分组节点夹在长链中间时，这一层省下的就是每个采样点的调用开销。
	return ModelNodeAccess.input_shape(self, &"in")

#endregion

#region 存档 / 调试

func params() -> Dictionary:
	return {"group": group}

func set_params(d: Dictionary) -> void:
	group = String(d.get("group", group))

func describe() -> String:
	if group.is_empty():
		return "分组[%s]" % id
	return "分组(%s)" % group

#endregion
