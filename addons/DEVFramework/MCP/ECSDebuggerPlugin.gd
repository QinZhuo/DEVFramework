@tool
## ECS 运行时查看器(EditorDebuggerPlugin) —— 游戏运行时在 Godot Debugger 面板新增 tab 显示:
##   · 每系统耗时 / 系统拓扑(执行顺序 + 是否可并行)
##   · 实体组件字段查看 + 改值(输入实体 ID → 展开组件字段 → 选中字段输入新值点"设置")
## 数据来自 World 节点的 EngineDebugger 推送(ecs_debug:view)与请求(ecs_debug)。
## 由 plugin.gd 创建并 add_debugger_plugin()。

class_name ECSDebuggerPlugin
extends EditorDebuggerPlugin

const PREFIX := "ecs_debug"

var _ui: Control = null
var _session: EditorDebuggerSession = null
var _tree: Tree = null
var _times_label: Label = null
var _entity_edit: LineEdit = null
var _value_edit: LineEdit = null


func _setup_session(session_id: int) -> void:
	var session := get_session(session_id)
	if session == null:
		return
	_session = session
	_build_ui()
	session.add_session_tab(_ui)
	session.started.connect(func() -> void:
		_request_view()
	)


func _has_capture(capture: String) -> bool:
	return capture.begins_with(PREFIX)


func _capture(message: String, data: Array, _session_id: int) -> bool:
	if not message.begins_with(PREFIX):
		return false
	_apply_data(data)
	return true


## 代码构建查看器 UI(编辑器侧, 调试面板 tab)。
func _build_ui() -> void:
	if _ui != null:
		return
	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_times_label = Label.new()
	_times_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_times_label)

	# 实体查看: 输入 ID + 按钮
	var hb := HBoxContainer.new()
	vb.add_child(hb)
	_entity_edit = LineEdit.new()
	_entity_edit.placeholder_text = "实体 ID"
	_entity_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(_entity_edit)
	var btn := Button.new()
	btn.text = "查看实体"
	btn.pressed.connect(func() -> void:
		var id: int = int(_entity_edit.text)
		if _session != null:
			_session.send_message(PREFIX, ["entity", id])
	)
	hb.add_child(btn)

	# 实体组件字段树
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_tree)

	# 改值: 新值输入 + 设置按钮(作用于选中的字段项)
	var hb2 := HBoxContainer.new()
	vb.add_child(hb2)
	_value_edit = LineEdit.new()
	_value_edit.placeholder_text = "新值(数字/向量/字符串)"
	_value_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb2.add_child(_value_edit)
	var btn2 := Button.new()
	btn2.text = "设置选中字段"
	btn2.pressed.connect(func() -> void:
		_apply_edit()
	)
	hb2.add_child(btn2)

	_ui = vb


func _request_view() -> void:
	if _session != null:
		_session.send_message(PREFIX, ["refresh"])


## 应用游戏推送的数据: [payload], payload = {systems, topology} 或 {entity, view}。
func _apply_data(data: Array) -> void:
	if data.is_empty() or not (data[0] is Dictionary):
		return
	var payload: Dictionary = data[0]
	if payload.has("systems"):
		var txt := "每系统耗时(ms):\n"
		for s in payload["systems"]:
			txt += "  %s: %.3f\n" % [s, payload["systems"][s]]
		if payload.has("topology"):
			txt += "拓扑(执行顺序):\n"
			for t in payload["topology"]["order"]:
				txt += "  %s%s\n" % [t["name"], "  (可并行)" if t["parallel"] else ""]
		_times_label.text = txt
	if payload.has("view"):
		_fill_entity_tree(int(payload.get("entity", -1)), payload["view"])


## 填充实体组件字段树(每个字段项带 meta 供改值)。
func _fill_entity_tree(entity: int, view: Dictionary) -> void:
	_tree.clear()
	var root := _tree.create_item()
	root.set_text(0, "实体 %d" % entity)
	for cn in view:
		var ci := root.create_child()
		ci.set_text(0, str(cn))
		for f in view[cn]:
			var fi := ci.create_child()
			fi.set_text(0, "%s = %s" % [f, str(view[cn][f])])
			fi.set_meta("entity", entity)
			fi.set_meta("comp", str(cn))
			fi.set_meta("field", str(f))


## 把选中字段的新值发给游戏进程(ecs.set_entity_field)。
func _apply_edit() -> void:
	var sel := _tree.get_selected()
	if sel == null or not sel.has_meta("entity") or _session == null:
		return
	_session.send_message(PREFIX, [
		"set", sel.get_meta("entity"), sel.get_meta("comp"), sel.get_meta("field"),
		_try_parse(_value_edit.text),
	])


## 尝试把输入字符串解析为数字/向量/字符串。
func _try_parse(s: String) -> Variant:
	if s.is_valid_float():
		return float(s)
	if s.is_valid_int():
		return int(s)
	if s.begins_with("(") and s.ends_with(")"):
		var parts := s.substr(1, s.length() - 2).split(",")
		if parts.size() == 2 and parts[0].is_valid_float() and parts[1].is_valid_float():
			return Vector2(float(parts[0]), float(parts[1]))
	return s
