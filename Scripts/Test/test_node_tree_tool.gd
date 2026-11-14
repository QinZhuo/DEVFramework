extends TestCase

## NodeTreeTool 的编排契约（原 ActorTool）：按**直接子节点**遍历，
## 只对"确实声明了该方法"的子节点调用；存档按子节点名收集，读档时缺 key 就跳过。
##
## 这条链错了不会报错：只是某一层没被初始化、或某个字段没被存下来。

class Probe extends Node:
	var calls: Array = []
	var loaded: Variant = null

	func game_init() -> void:
		calls.append("init")

	func game_ready() -> void:
		calls.append("ready")

	func save_data() -> Variant:
		return {"name": name}

	func load_data(data) -> void:
		loaded = data


class Plain extends Node:
	pass


func _root_with(children: Array) -> Node:
	var root := Node.new()
	for c in children:
		root.add_child(c)
	return root


func test_calls_only_children_declaring_the_method() -> void:
	var a := Probe.new()
	var b := Probe.new()
	a.name = "A"
	b.name = "B"
	var plain := Plain.new()
	var root := _root_with([a, plain, b])

	await NodeTreeTool.game_init(root)
	assert_eq(a.calls, ["init"], "有该方法的子节点应被调用")
	assert_eq(b.calls, ["init"], "多个子节点都应被调用")

	await NodeTreeTool.game_ready(root)
	assert_eq(a.calls, ["init", "ready"], "game_ready 是另一个钩子，不应串")
	root.free()


## 只处理直接子节点：孙节点的方法不会被顺手调用（避免"层级越权"）。
func test_does_not_recurse_into_grandchildren() -> void:
	var grand := Probe.new()
	var child := Node.new()
	child.add_child(grand)
	var root := _root_with([child])

	await NodeTreeTool.game_init(root)
	assert_eq(grand.calls, [], "孙节点不应被调用 —— 递归会打乱初始化顺序")
	root.free()


func test_save_data_is_keyed_by_child_name() -> void:
	var a := Probe.new()
	a.name = "Alpha"
	var b := Probe.new()
	b.name = "Beta"
	var root := _root_with([a, Plain.new(), b])

	var data = await NodeTreeTool.save_data(root)
	assert_true(data.has("Alpha") and data.has("Beta"), "每个有 save_data 的子节点都应有条目")
	# 子节点在 save_data 返回的 name 是 StringName，与 String 不相等 —— 取 str 再比
	assert_eq(str(data["Alpha"]["name"]), "Alpha", "存档值应原样来自子节点")
	root.free()


func test_load_data_skips_unknown_keys() -> void:
	var a := Probe.new()
	a.name = "Alpha"
	var b := Probe.new()
	b.name = "Beta"
	var root := _root_with([a, b])

	await NodeTreeTool.load_data(root, {"Alpha": 1})
	assert_eq(a.loaded, 1, "匹配到的子节点应收到数据")
	assert_true(b.loaded == null, "data 里没有的子节点应被跳过，而不是塞 null")

	await NodeTreeTool.load_data(root, null)
	assert_eq(a.loaded, 1, "data 为 null 时应整体跳过（新开档）")
	root.free()


func test_is_alive_checks_instance_tree_and_visibility() -> void:
	assert_false(NodeTreeTool.is_alive(null), "null 不算存活")

	var n := Node2D.new()
	assert_false(NodeTreeTool.is_alive(n), "不在树里不算存活")
	n.free()
	assert_false(NodeTreeTool.is_alive(n), "已释放不算存活")
