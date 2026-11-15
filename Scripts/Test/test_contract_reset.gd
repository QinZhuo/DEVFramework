extends TestCase

## 契约：含 `static var` 的 XxxTool 必须被 ResetTool 登记，或在类文件头标 `## Reset: 进程级`。
## 目的：新增带会话状态的工具忘了登记复位 → 直接红灯，而不是等切场景串味才发现。

const ROOT := "res://addons/DEVFramework/"
const REGISTRY := "res://addons/DEVFramework/Core/Tool/ResetTool.gd"
const EXEMPT := "## Reset: 进程级"

var _class_re := RegEx.create_from_string("(?m)^class_name\\s+(\\w+)")
var _state_re := RegEx.create_from_string("(?m)^static var\\s")


func test_stateful_tools_are_registered() -> void:
	var registry := FileAccess.get_file_as_string(REGISTRY)
	assert_true(registry != "", "读不到 %s" % REGISTRY)
	var missing: Array[String] = []
	for path in FileTool.list_files(ROOT, PackedStringArray([".gd"])):
		var text := FileAccess.get_file_as_string(path)
		var m := _class_re.search(text)
		if m == null:
			continue
		var cls := m.get_string(1)
		if not cls.ends_with("Tool") or not _state_re.search(text):
			continue
		if text.contains(EXEMPT) or registry.contains(cls + "."):
			continue
		missing.append("%s(%s)" % [cls, path.get_file()])
	assert_true(missing.is_empty(), "有 static var 但未登记复位: %s" % ", ".join(missing))
