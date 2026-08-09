class_name ECSSyncSystem
extends ECSSystem

## ECSSyncSystem —— 批量把 ECS 字段同步到 Godot 节点属性。
##
## 设计:
##   - NodeLink 只保存 实体↔节点 关联(node_path)
##   - **同步哪些字段由 add_field_rule 注册的规则决定**(位置也是规则, 如 pos → position)
##   - 每帧: 遍历带 NodeLink 的实体, 按 comp 分组, 每 comp 一次 query_aligned + 一次实体遍历,
##     同时应用该 comp 的全部规则字段(合并遍历, 免每规则一次遍历)
##
## 用法:
##   var sync_sys := ECSSyncSystem.new()
##   sync_sys.add_field_rule(DemoQueryBall, &"pos", &"position")    # 位置
##   sync_sys.add_field_rule(DemoQueryBall, &"size", &"visual_size") # 任意字段
##   world.register_system(sync_sys)

## 场景根节点(查找 NodeLink.node_path 用)。若未设置, 默认取当前场景根。
var scene_root: Node = null

## 渲染开关: false 时跳过全部同步(纯数值逻辑), 由持有方(如 DemoImpl)控制。
var render_enabled := true

## 节点缓存: NodeLink 行号 -> Node(数组索引 O(1))。NodeLink 实体数变化时重建。
var _nl_nodes: Array = []
var _nl_count := -1

## 同步规则(预编译为数组, 避免每实体 dict 遍历):
## [{comp, fields: PackedStringArray, props: PackedStringArray}] — 数组索引替代 dict 查
var _rule_items: Array = []

## 对齐行号缓存: comp -> query_aligned(NodeLink, [comp]) 结果(实体结构变化时清空)
var _aligned_cache := {}


## 注册一条字段同步规则: 把 ECS 组件 comp 的 field 字段同步到关联节点的 node_prop 属性。
func add_field_rule(comp, field: StringName, node_prop: StringName) -> void:
	for item in _rule_items:
		if item.comp == comp:
			item.fields.append(field)
			item.props.append(node_prop)
			return
	var new_item := {
		"comp": comp,
		"fields": PackedStringArray([field]),
		"props": PackedStringArray([node_prop]),
	}
	_rule_items.append(new_item)


func required_components() -> Array[Script]:
	return [NodeLink]

## 访问场景树/节点 → 必须主线程串行, 不可并行。
func can_run_parallel() -> bool:
	return false


func _run(ctx: ECSSystemContext, _delta: float) -> void:
	if not render_enabled:
		return
	var w := ctx.world
	if w == null or _rule_items.is_empty():
		return
	if scene_root == null:
		var tree := Engine.get_main_loop() as SceneTree
		scene_root = tree.current_scene if tree else null
	if scene_root == null:
		return

	var rows: PackedInt32Array = w.query_rows(NodeLink, [], [])
	if rows.is_empty():
		return
	var paths: PackedStringArray = w.get_column(NodeLink, &"node_path")

	# 节点缓存(行号 -> node), 结构变化(实体数)时重建并清空对齐缓存
	if _nl_count != rows.size():
		_nl_count = rows.size()
		_aligned_cache.clear()
		_nl_nodes.resize(rows.size())
		for e in rows:
			_nl_nodes[e] = scene_root.get_node_or_null(paths[e])

	for item in _rule_items:
		var comp = item.comp
		var fields: PackedStringArray = item.fields
		var props: PackedStringArray = item.props
		# 对齐行号(缓存): aligned[0]=NodeLink 行号, aligned[1]=comp 行号(同一 k 索引)
		var aligned: Variant = _aligned_cache.get(comp)
		if aligned == null:
			aligned = w.query_aligned(NodeLink, [comp])
			_aligned_cache[comp] = aligned
		if aligned.size() < 2:
			continue
		var nl_rows_a: PackedInt32Array = aligned[0]
		var comp_rows_a: PackedInt32Array = aligned[1]
		# 一次拉取该 comp 全部规则字段列(数组对齐, 循环内数组索引)
		var cols: Array = []
		for f in fields:
			cols.append(w.get_column(comp, StringName(f)))
		var n_fields := fields.size()
		for k in nl_rows_a.size():
			var nl_row := nl_rows_a[k]
			var node: Node = _nl_nodes[nl_row]
			if node == null:
				continue
			var comp_row := comp_rows_a[k]
			if comp_row < 0:
				continue
			# 索引赋值 node[prop] = v(性能≈直接赋值, 通用, 省 node.set 动态解析)
			for fi in n_fields:
				var col = cols[fi]
				if comp_row >= col.size():
					continue
				node[props[fi]] = col[comp_row]
