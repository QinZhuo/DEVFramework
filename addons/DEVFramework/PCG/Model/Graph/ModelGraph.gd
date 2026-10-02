@tool
class_name ModelGraph extends RefCounted
## 模型生成图 —— 一张有向无环图，把 [ModelNode] 连成"怎么长出这个模型"的配方
##
## ============================ 为什么要有图 ============================
## 手写 [method PropGen.build] 的问题不是慢，是**不可复用**：
## 想把"圆角盒 + 四条圆柱腿"这套做法用到别的东西上，只能复制粘贴整个函数；
## 想改一个参数得翻遍代码；想做多风格就得复制一份生成器。
##
## 图把这三件事解掉：
## · **复用** —— 子图即零件，"街道段"可以引用"人行道"子图；
## · **参数化** —— 数值是节点字段，改风格不必改结构；
## · **非破坏性** —— 换 seed / 换风格 / 换精度都是重新求值，源配方不变。
##   这与 Houdini 的 SOP 网络、Blender 的几何节点是同一套思路。
##
## ============================ 三条设计红线 ============================
## ① **确定性**：每个节点拿到的 rng 由 (图种子, 节点 id 字典序排名) 派生，
##    而非插入顺序 —— 改图的连线顺序不该改变任何形状。
## ② **无世界坐标**：图只产出局部空间的场。摆放是 [PropLayoutTool] 的事。
## ③ **拓扑序是唯一求值顺序**：包围盒沿拓扑序前向传播，形状沿拓扑序前向合成，
##    post 沿拓扑序后向执行。各节点因此不需要知道彼此的存在。
##
## == 典型用法 ==
## [codeblock]
## var g := ModelGraph.new()
## var body := g.add(ModelBoxNode.new(), &"body") as ModelBoxNode
## body.half = Vector3(1.0, 1.2, 1.0)
## g.link(&"legs", &"in", &"body")
## var field := g.evaluate(0.05)
## [/codeblock]

## 场原点相对图局部原点的取法。决定烘焙结果落在哪，
## **不改变任何节点的形状** —— 换 pivot 只挪位置，不挪随机数派生，
## 因此"换风格 / 换摆放基准"不会意外改变形状。
enum Pivot {
	KEEP,        ## 场原点 = 图局部原点（几何可以悬空、可以跨 y=0）
	FLOOR,       ## 场原点抬到几何最低点 → 结果满足全框架的"最低点 y=0"摆放约定
	CENTER_XZ,   ## 同 FLOOR，且 XZ 也居中 → 模型绕自身轴旋转时不会绕着偏心点转
}

## 场原点取法。默认 [constant Pivot.FLOOR]，与 [PropGen] 系列的摆放约定一致。
var pivot := Pivot.FLOOR

## 场分块边长（体素数）。与 [SdfField] 默认值一致，不建议改。
const CHUNK_SIZE := 32

## 种子派生的 kind 常量。与 [PropGenTool.mix_seed] 配套，同族节点用同一个。
const RNG_KIND := 7

## 场包围盒的安全余量（体素边长的倍数）。默认 3 倍，与 [SdfField] 默认窄带一致。
## 几何贴到 bounds 边缘时靠它留缓冲，否则等值面会被场边界截断（缺面）。
const DEFAULT_MARGIN_VOXELS := 3.0

## 图种子。同一图 + 同一种子必得完全相同的场与网格。
var seed_value := 0

## 输出节点 id。有多个输出节点时取 id 字典序最小者，建议显式指定。
var root_id: StringName = &""

## id → 节点
var nodes := {}
## id → {端口名: 上游节点 id}
var links := {}

# ---------------------------------------------------------------- 求值缓存

var _order := PackedStringArray()
var _order_ready := false
var _index := {}                  ## id → 稳定序号（字典序排名）
var _shape_memo := {}
var _bounds_memo := {}
var _cur: ModelNode = null        ## 当前正在求值的节点，供节点问自己的输入

# ================================================================== 组装

## 加入一个节点。id 为空时取节点 [method ModelNode.describe] 的结果。
## 返回加入后的节点，方便链式写。
func add(node: ModelNode, p_id: StringName = &"") -> ModelNode:
	if node == null:
		return null
	var nid := p_id
	if nid == &"":
		nid = StringName(node.describe())
	nodes[nid] = node             ## 允许覆写同名节点，但缓存必须失效
	node.id = nid
	if root_id == &"" or String(nid) < String(root_id):
		root_id = nid
	_invalidate()
	return node

## 连接：`child` 的 `port` 端口接 `parent` 的输出。
## port 留空表示接该节点第一个端口。连线后 child 在拓扑上必须**晚于** parent。
func link(child: StringName, port: StringName, parent: StringName) -> void:
	if not nodes.has(child):
		push_error("[ModelGraph] link 的下游节点不存在：%s" % child)
		return
	if not nodes.has(parent):
		push_error("[ModelGraph] link 的上游节点不存在：%s" % parent)
		return
	var n: ModelNode = nodes[child]
	var p := port
	if p == &"":
		var ps := n.ports()
		p = ps[0] if ps.size() > 0 else &"in"
	var d: Dictionary = links.get(child, {})
	d[p] = parent
	links[child] = d
	_invalidate()

## 断开一个端口。
func unlink(child: StringName, port: StringName) -> void:
	if not links.has(child):
		return
	var d: Dictionary = links[child]
	d.erase(port)
	if d.is_empty():
		links.erase(child)
	_invalidate()

func has(id: StringName) -> bool:
	return nodes.has(id)

func node_of(id: StringName) -> ModelNode:
	return nodes.get(id, null)

func size() -> int:
	return nodes.size()

func ids() -> PackedStringArray:
	return _sorted_ids()

func _invalidate() -> void:
	_order_ready = false
	_index.clear()
	_shape_memo.clear()
	_bounds_memo.clear()

## 换种子并清空求值缓存。
##
## **不要**直接写 `g.seed_value = x`：形状缓存（[member _shape_memo]）是按旧种子
## 建好的，不清就会拿到"新种子配旧形状"的诡异结果 —— 这类 bug 表现为
## "改 seed 后某些部位没变"，极难定位。
func set_seed(p_seed: int) -> void:
	if seed_value == p_seed:
		return
	seed_value = p_seed
	_shape_memo.clear()

# ================================================================== 拓扑

## 拓扑序（上游在前）。DFS 后序，遍历按 id 字典序 —— 保证确定性。
## 图中有环时报错并截断该分支（其余部分仍可求值，便于调试图结构）。
func topo() -> PackedStringArray:
	if _order_ready:
		return _order
	_order = PackedStringArray()
	var ok := true
	var state := {}
	for n in _sorted_ids():
		if not _visit(n, state, _order):
			ok = false
	if not ok:
		push_error("[ModelGraph] 图中存在环，求值已截断；请检查连线方向")
	_order_ready = true
	return _order

func _visit(id: StringName, state: Dictionary, out: PackedStringArray) -> bool:
	var st: int = state.get(id, 0)
	if st == 2:
		return true
	if st == 1:
		push_error("[ModelGraph] 检测到环：经过 %s" % id)
		return false
	state[id] = 1
	var d: Dictionary = links.get(id, {})
	for port in _sorted_ports(id):
		var up: StringName = d.get(port, &"")
		if up != &"" and nodes.has(up) and not _visit(up, state, out):
			return false
	state[id] = 2
	out.append(id)
	return true

## 按 id 字典序排序 —— 一切"遍历顺序"都走它，保证同图必同序。
func _sorted_ids() -> PackedStringArray:
	var arr: Array = nodes.keys()
	arr.sort()
	var out := PackedStringArray()
	for k in arr:
		out.append(k)
	return out

func _sorted_ports(id: StringName) -> Array:
	var d: Dictionary = links.get(id, {})
	var arr: Array = d.keys()
	arr.sort()
	return arr

## 稳定序号：id 在字典序中的排名。与插入顺序无关，故改连线不改形状。
func stable_index(id: StringName) -> int:
	if _index.is_empty():
		var sorted_ids := _sorted_ids()
		for i in sorted_ids.size():
			_index[sorted_ids[i]] = i
	return _index.get(id, 0)

# ================================================================== 种子

## 节点专属随机源。由 (图种子, 稳定序号) 派生。
##
## 复用 PropGenTool 的两个种子工具而非自己写：那里的注释记录了
## PCG32 的 `state = seed` 退化坑，重复实现等于把同一个坑重踩一遍。
func rng_for(id: StringName) -> RandomNumberGenerator:
	return PropGenTool.make_rng(PropGenTool.mix_seed(seed_value, RNG_KIND, stable_index(id)))

## 当前正在求值的节点（测试与调试用）。
func current_node() -> ModelNode:
	return _cur

## 取输入端口的上游形状。未连接时返回 [method ModelNode.null_shape]，
## 于是 union/subtract 对空端口天然可解 —— 图容忍半接线状态。
func input_shape(port: StringName) -> Callable:
	var up := _input_of(port)
	if up != &"" and _shape_memo.has(up):
		return _shape_memo[up]
	return ModelNode.null_shape

## 取输入端口的上游包围盒。未连接时返回空 AABB（size 全 0）。
func input_bounds(port: StringName) -> AABB:
	var up := _input_of(port)
	if up == &"":
		return AABB()
	return _bounds_memo.get(up, AABB())

## 取输入端口的上游节点 id（未连接返回空 StringName）。
func input_id(port: StringName) -> StringName:
	return _input_of(port)

func _input_of(port: StringName) -> StringName:
	if _cur == null:
		return &""
	var d: Dictionary = links.get(_cur.id, {})
	var up: StringName = d.get(port, &"")
	return up if nodes.has(up) else &""

# ================================================================== 求值

## 沿拓扑序合成根节点的 SDF 形状函数。纯构图，不碰场。
func build_shape() -> Callable:
	_prepare()
	for id in _order:
		var n: ModelNode = nodes[id]
		_cur = n
		_shape_memo[id] = n.shape(rng_for(id))
	_cur = null
	if _shape_memo.has(root_id):
		return _shape_memo[root_id]
	return ModelNode.null_shape

## 沿拓扑序计算各节点包围盒，返回根节点 AABB（局部空间，米）。
func bounds() -> AABB:
	_prepare()
	for id in _order:
		var n: ModelNode = nodes[id]
		_cur = n
		_bounds_memo[id] = n.bounds_hint()
	_cur = null
	return _bounds_memo.get(root_id, AABB())

## 按根包围盒分配一块恰好够用的场。
##
## [method fill] 与 [method evaluate] 用的形状函数收到的是**场局部坐标**
## （= 图局部坐标 − 场原点），所以分配时必须把包围盒也平移到同一坐标系里，
## 否则几何会整体错位（表现为缺面或整体偏移）。
func make_field(p_voxel_size: float, p_margin := -1.0) -> SdfField:
	var vs := p_voxel_size if p_voxel_size > 0.0 else 0.1
	var mg := p_margin if p_margin >= 0.0 else vs * DEFAULT_MARGIN_VOXELS
	var b := bounds().grow(mg)
	var org := _pivot_offset(b)
	var f := SdfField.create(CHUNK_SIZE, vs, org, -1.0)
	SdfTool.allocate_cells(f, _cell_lo(b.position - org, vs), _cell_hi(b.end - org, vs))
	return f

## 场原点（世界/图局部坐标）。见 [member pivot]。
func _pivot_offset(b: AABB) -> Vector3:
	match pivot:
		Pivot.FLOOR:
			return Vector3(0.0, b.position.y, 0.0)
		Pivot.CENTER_XZ:
			var c := b.get_center()
			return Vector3(c.x, b.position.y, c.z)
		_:
			return Vector3.ZERO

func _cell_lo(p: Vector3, vs: float) -> Vector3i:
	return Vector3i(floori(p.x / vs) - 1, floori(p.y / vs) - 1, floori(p.z / vs) - 1)

func _cell_hi(p: Vector3, vs: float) -> Vector3i:
	return Vector3i(ceili(p.x / vs) + 1, ceili(p.y / vs) + 1, ceili(p.z / vs) + 1)

## 把形状灌进已分配好的场，再按拓扑序跑完各节点的 post。
##
## post 会改写 field 的 data 使窄带缓存失效，这里在**所有** post 之后统一重算一次，
## 所以 [method ModelNode.post] 的实现里不必自己调 [method SdfTool.refresh_band_bounds]。
func fill(field: SdfField) -> void:
	if field == null or field.is_empty():
		return
	SdfTool.fill(field, build_shape())
	for id in _order:
		(nodes[id] as ModelNode).post(field)
	SdfTool.refresh_band_bounds(field)

## 一步到位：分配场 → 灌形状 → 跑 post。
## [param p_voxel_size] <= 0 时退化为 0.1 m（粗到只适合看轮廓）。
func evaluate(p_voxel_size := 0.1, p_margin := -1.0) -> SdfField:
	var f := make_field(p_voxel_size, p_margin)
	fill(f)
	return f

func _prepare() -> void:
	if _order_ready:
		return
	_shape_memo.clear()
	_bounds_memo.clear()
	## 回灌图引用：[method ModelGraph.input_shape] / `input_bounds` 是**实例方法**
	## （内部靠 `_cur` 判断"我是谁"），而节点的 `shape(rng)` / `bounds_hint()` 签名里
	## 没有图，于是多输入节点（布尔 / 变换 / 阵列 / 分组）根本没有途径问自己的输入。
	## 这一行就是补上那条线；鸭子类型，只对实现了 `bind_graph` 的节点生效，
	## 因此老节点（以及外部自定义节点）零改动，未实现的仍走"端口悬空"语义。
	ModelNodeAccess.bind_all(self)
	topo()                       ## 建立 _order（同时填好 _index）

# ================================================================== 校验

## 返回问题清单（空数组 = 图可求值）。测试与编辑器用它自检。
func validate() -> Array:
	var problems: Array = []
	if nodes.is_empty():
		problems.append("图是空的")
		return problems
	if not nodes.has(root_id):
		problems.append("输出节点 %s 不存在" % root_id)
	for id in _sorted_ids():
		var n: ModelNode = nodes[id]
		var declared := n.ports()
		var d: Dictionary = links.get(id, {})
		for port in d.keys():
			if not declared.has(port):
				problems.append("节点 %s 没有端口 %s" % [id, port])
			if not nodes.has(d[port]):
				problems.append("节点 %s 的端口 %s 接到了不存在的上游" % [id, port])
	topo()                       ## 触发一次环检测（环已在上报）
	return problems

# ================================================================== 存档

## 图配方存档。存的是**结构 + 参数**，不含任何场数据或网格 ——
## 读回来重求值即可，与"存档只存 seed"同思路，但粒度更细：
## 连搭法一起存，因此换 seed 时形状逻辑保持不变。
func to_data() -> Dictionary:
	var ns: Array = []
	for id in _sorted_ids():
		var n: ModelNode = nodes[id]
		ns.append({
			"id": String(id),
			"type": (n.get_script() as GDScript).get_global_name(),
			"params": n.params(),
		})
	var ls: Array = []
	for id in _sorted_ids():
		var d: Dictionary = links.get(id, {})
		for port in _sorted_ports(id):
			ls.append({"c": String(id), "p": String(port), "u": String(d[port])})
	return {"v": 1, "seed": seed_value, "root": String(root_id), "nodes": ns, "links": ls}

## 从存档重建图。未知节点类型 / 悬空连线会报错并跳过，不会静默插一个空节点。
static func from_data(d: Dictionary) -> ModelGraph:
	var g := ModelGraph.new()
	g.seed_value = int(d.get("seed", 0))
	for row in d.get("nodes", []):
		if not (row is Dictionary):
			continue
		var type_name := String((row as Dictionary).get("type", ""))
		var script := _script_of(type_name)
		if script == null:
			push_error("[ModelGraph] 存档里的未知节点类型：%s（已跳过）" % type_name)
			continue
		var inst := (script as GDScript).new() as ModelNode
		inst.set_params((row as Dictionary).get("params", {}))
		g.add(inst, StringName((row as Dictionary).get("id", type_name)))
	for row in d.get("links", []):
		if not (row is Dictionary):
			continue
		var c := StringName((row as Dictionary).get("c", ""))
		var u := StringName((row as Dictionary).get("u", ""))
		if g.has(c) and g.has(u):
			g.link(c, StringName((row as Dictionary).get("p", "")), u)
		else:
			push_error("[ModelGraph] 存档连线两端缺失：%s ← %s（已跳过）" % [c, u])
	var r := StringName(d.get("root", ""))
	if g.has(r):
		g.root_id = r
	g._invalidate()
	return g

## 按全局类名找脚本。走 ProjectSettings 的全局类表，不硬 load 未知路径。
static func _script_of(type_name: String) -> GDScript:
	if type_name == "":
		return null
	var map: Dictionary = ProjectSettings.get_setting("global_script_class_cache", {})
	if not map.has(type_name):
		return null
	var rec: Variant = map[type_name]
	if not (rec is Dictionary):
		return null
	var path := String((rec as Dictionary).get("path", ""))
	if path == "":
		return null
	return load(path) as GDScript

# ================================================================== 便捷

## 深拷贝：节点逐个克隆、参数照搬、连线照搬。
## 用于"同一张图派生多个变体"（不同 seed / 不同风格）。
func clone() -> ModelGraph:
	var g := ModelGraph.new()
	g.seed_value = seed_value
	for id in _sorted_ids():
		var src: ModelNode = nodes[id]
		var dst: ModelNode = src.make_instance()
		dst.set_params(src.params())
		g.add(dst, id)
	for id in _sorted_ids():
		var d: Dictionary = links.get(id, {})
		for port in _sorted_ports(id):
			g.link(id, StringName(port), d[port])
	if g.has(root_id):
		g.root_id = root_id
	return g

## 换种子重求值的便捷入口（不改本图，返回新场）。
func evaluate_with_seed(p_seed: int, p_voxel_size := 0.1) -> SdfField:
	var old := seed_value
	seed_value = p_seed
	var f := evaluate(p_voxel_size)
	seed_value = old
	return f

func describe() -> String:
	return "ModelGraph(%d 节点, 种子 %d, 输出 %s)" % [nodes.size(), seed_value, root_id]
