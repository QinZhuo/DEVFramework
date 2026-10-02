@tool
class_name ModelNodeAccess
## 节点访问图的唯一入口 —— 补上 [ModelNode] 到 [ModelGraph] 之间缺的那一根线
##
## ============================ 为什么需要它 ============================
## [method ModelGraph.input_shape] / [method ModelGraph.input_bounds] 是**实例方法**
## （内部靠私有的 `_cur` 判断"我是谁"）。但 [method ModelNode.shape] 与
## [method ModelNode.bounds_hint] 的签名里只有 `rng` / 无参，
## 节点**没有任何途径拿到图**，于是"取输入形状"这条契约在实现层是断的。
##
## 本类是这条线的实现：[method ModelGraph._prepare] 第一件事就调
## [method bind_all]，把图回灌给每个实现了 `bind_graph` 的节点
## （鸭子类型，故不依赖 ModelNode 的改动；没有该方法的节点静默跳过）。
## 图求值的三个入口 `build_shape` / `bounds` / `make_field` 都过 `_prepare()`，
## 所以正常路径不需要任何手动绑定。
##
## == 多图并存：`bound` 是"最后 bind 的赢" ==
## [member bound] 是静态变量，只记录最近一次登记的图。因此
## **求值必须从 [ModelGraph] 的公开入口进**：直接缓存节点调 `shape()` /
## `bounds_hint()` 会拿到上一张图的残留，多输入节点就会问错图。
## 节点自己的 `graph` 字段没有这个歧义（逐节点持有），它才是首选来源。
##
## 两者都拿不到图时（例如节点被单独 new 出来做调试），
## `input_shape` 退化为 [method ModelNode.null_shape]、`input_bounds` 退化为空 AABB
## —— 即"端口悬空"的既定语义：**少接一根线不会崩，只会得到可预期的形状**。
##
## 全部静态、无状态。节点侧只需两行：
## [codeblock]
## var graph: ModelGraph = null                     ## 由 bind_graph 回灌
## func bind_graph(g: ModelGraph) -> void: graph = g
## func shape(rng: RandomNumberGenerator) -> Callable:
##     var src := ModelNodeAccess.input_shape(self, &"in")
##     return func(p: Vector3) -> float: return src.call(p)
## [/codeblock]
##
## 注意必须写 [code]src.call(p)[/code]：GDScript 4 **不允许**用 [code]src(p)[/code]
## 直接调用 Callable 变量，解析器会当成"调用本对象上的 src 方法"，
## 编译期直接报 [code]Function "src()" not found in base self.[/code]

## 最近一次 [method bind_all] 登记的图。作为节点取不到 `graph` 字段时的兜底。
static var bound: ModelGraph = null

## 把图回灌给一个节点。无 `bind_graph` 方法的节点静默跳过。
static func bind_graph(p_node: ModelNode, p_graph: ModelGraph) -> void:
	if p_node != null and p_graph != null and p_node.has_method(&"bind_graph"):
		p_node.call(&"bind_graph", p_graph)

## 登记整张图：写入 `bound` 并逐个回灌。
## 由 [method ModelGraph._prepare] 调用（它是一切求值的前置步骤）。
static func bind_all(p_graph: ModelGraph) -> void:
	bound = p_graph
	if p_graph == null:
		return
	for n in p_graph.nodes.values():
		bind_graph(n as ModelNode, p_graph)

## 解除登记（换图求值前调用，避免拿上一张图的残留）。
static func clear() -> void:
	bound = null

## 取输入端口的上游形状。悬空/无图时返回 [method ModelNode.null_shape]（恒 1e9）。
static func input_shape(p_node: ModelNode, p_port: StringName) -> Callable:
	var g := _graph_of(p_node)
	if g == null:
		return ModelNode.null_shape
	return g.input_shape(p_port)

## 取输入端口的上游包围盒。悬空/无图时返回空 AABB（size 全 0）。
static func input_bounds(p_node: ModelNode, p_port: StringName) -> AABB:
	var g := _graph_of(p_node)
	if g == null:
		return AABB()
	return g.input_bounds(p_port)

## 取输入端口的上游节点 id（未连接返回空 StringName）。
static func input_id(p_node: ModelNode, p_port: StringName) -> StringName:
	var g := _graph_of(p_node)
	if g == null:
		return &""
	return g.input_id(p_port)

## 节点身上的 `graph` 字段（鸭子类型读取，字段不存在则为 null）→ 兜底 `bound`。
static func _graph_of(p_node: ModelNode) -> ModelGraph:
	if p_node != null:
		var g: Variant = p_node.get(&"graph")
		if g is ModelGraph:
			return g as ModelGraph
	return bound

## 空 AABB 判定：未连接端口返回 `AABB()`（size 全 0）。
## 布尔/分组节点据此跳过"与空盒子求并集"这一步 —— 并上零尺寸盒子
## 会把盒子的**位置**（原点）也算进去，凭空长出一块几何。
static func is_empty_box(b: AABB) -> bool:
	return b.size.length_squared() <= 0.0

## 并集（空盒子视为单位元）。比 `a.merge(b)` 多了"忽略空盒"的语义。
static func merge(a: AABB, b: AABB) -> AABB:
	if is_empty_box(a):
		return b
	if is_empty_box(b):
		return a
	return a.merge(b)

## 用 [param b] 变换 [param box] 的 **8 个角点**后取 min/max。
##
## 为什么必须变换 8 个角点而不是只变换 min/max 两个角点：
## 旋转 45° 时，只变换 min/max 角点得到的盒子在两个方向上都是**原盒子边缘**
## （恰好擦过对角），旋转后的真实盒子在各轴上的投影都比它大 ——
## 于是几何的角会被场边界截断，表现为缺面 / 削角。
## 成本是 8 次点积，相对"每体素一次形状求值"可以忽略，没有理由省。
static func xform_aabb(b: Basis, box: AABB, offset := Vector3.ZERO) -> AABB:
	if is_empty_box(box):
		return AABB()
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for i in 8:
		var corner := Vector3(
			box.end.x if (i & 1) else box.position.x,
			box.end.y if (i & 2) else box.position.y,
			box.end.z if (i & 4) else box.position.z)
		var w := b * corner + offset
		mn = mn.min(w)
		mx = mx.max(w)
	return AABB(mn, mx - mn)

## 由 8 个世界点直接求 AABB（阵列节点逐实例变换后合并用）。
static func aabb_of_points(pts: Array[Vector3]) -> AABB:
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for p in pts:
		mn = mn.min(p)
		mx = mx.max(p)
	return AABB(mn, mx - mn)
