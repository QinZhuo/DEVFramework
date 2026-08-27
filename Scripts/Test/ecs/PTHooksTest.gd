class_name PTHooksTest
extends RefCounted

## ④ 组件生命周期钩子(on_add/on_remove/on_destroy) + 变化检测 自检。

static var events: Array = []
static var all_ok := true

static func _on_add(entity: int) -> void:
	events.append(["add", entity])

static func _on_remove(entity: int) -> void:
	events.append(["remove", entity])

static func _on_destroy(entity: int) -> void:
	events.append(["destroy", entity])

static func _tag(name: String, cond: bool) -> void:
	if not cond:
		all_ok = false
	print("[Hooks] ", name, " = ", cond)

static func run() -> bool:
	all_ok = true
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	w.register_component(PTCompB)
	events.clear()
	w.on_component_added(PTCompA, PTHooksTest._on_add)
	w.on_component_removed(PTCompA, PTHooksTest._on_remove)
	w.on_entity_destroyed(PTHooksTest._on_destroy)

	# ---- 立即版 add/remove + 变化检测 ----
	var e1 := w.create_entity()
	w.add_component(e1, PTCompA)
	w.add_component(e1, PTCompB)
	_tag("add_fired", events.size() == 1 and events[0][0] == "add" and events[0][1] == e1)
	_tag("add_component_not_dirty", not w.is_component_dirty(PTCompA))
	events.clear()
	w.set_field(e1, PTCompA, &"x", 5)
	_tag("set_field_dirty", w.is_component_dirty(PTCompA))
	_tag("dirty_list", w.dirty_components().has(&"PTCompA"))
	w.set_column(PTCompA, &"x", PackedInt32Array([7, 7]))
	_tag("set_column_dirty", w.is_component_dirty(PTCompA))
	# get_column 只读, 不标记
	events.clear()
	var col: PackedInt32Array = w.get_column(PTCompA, &"x")
	w.remove_component(e1, PTCompA)
	_tag("remove_fired", events.size() == 1 and events[0][0] == "remove" and events[0][1] == e1)

	# ---- destroy 触发 remove + on_destroy ----
	w.add_component(e1, PTCompA)
	events.clear()
	w.destroy_entity(e1)
	_tag("destroy_remove_fired", events.size() == 2 and events[0][0] == "remove"
			and events[1][0] == "destroy" and events[1][1] == e1)

	# ---- 命令缓冲版: cmd_create + cmd_add_component 占位实体 -> flush 后触发 ----
	events.clear()
	var h := w.cmd_create()
	w.cmd_add_component(h, PTCompA)
	w.cmd_flush()
	_tag("cmd_add_fired", events.size() == 1 and events[0][0] == "add")

	# ---- 命令缓冲版: cmd_destroy -> flush 后触发 remove + on_destroy ----
	events.clear()
	var e2 := w.create_entity()
	w.add_component(e2, PTCompA)
	events.clear()
	w.cmd_destroy(e2)
	w.cmd_flush()
	_tag("cmd_destroy_fired", events.size() == 2 and events[0][0] == "remove"
			and events[1][0] == "destroy")
	return all_ok
