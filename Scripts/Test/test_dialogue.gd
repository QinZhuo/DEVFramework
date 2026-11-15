class_name test_dialogue
extends TestCase

## 对话模块功能测试。
## 覆盖 DialogueTool.play() 走的那条链路: DialogueScriptDef → DialogueSession 逐行推进。
## 之前 play() 没有任何调用方, 等于"未验证的死代码" —— 这里把行为钉住。


func _make_script(texts: Array) -> DialogueScriptDef:
	var script := DialogueScriptDef.new()
	var lines: Array[DialogueLineDef] = []
	for t in texts:
		var line := DialogueLineDef.new()
		line.text = t
		lines.append(line)
	script.lines = lines
	return script


func test_advances_line_by_line() -> void:
	var script := _make_script(["第一行", "第二行"])
	var seen: Array[int] = []
	var session := DialogueSession.new(script)
	session.line_changed.connect(func(_line, i: int) -> void: seen.append(i))

	assert_true(session.start(), "非空脚本应能开始")
	assert_true(session.current() == script.lines[0], "开始后应在第一行")
	assert_true(session.next(), "应能推进到第二行")
	assert_true(session.current() == script.lines[1], "推进后应在第二行")
	assert_true(not session.next(), "两行播完 next() 应返回 false")
	assert_true(seen.size() == 2, "应收到 2 次 line_changed, 实际 %d" % seen.size())


func test_empty_script_cannot_start() -> void:
	var session := DialogueSession.new(_make_script([]))
	assert_true(not session.start(), "空脚本不应开始")
	assert_true(session.current() == null, "空脚本当前行应为 null")


func test_cancel_stops_running() -> void:
	var session := DialogueSession.new(_make_script(["唯一一行"]))
	var cancelled := [false]
	session.cancelled.connect(func() -> void: cancelled[0] = true)
	session.start()
	session.cancel()
	assert_true(cancelled[0], "cancel() 应发出 cancelled")
	assert_true(not session.running, "cancel() 后 running 应为 false")


func test_loop_wraps_to_first_line() -> void:
	var script := _make_script(["A", "B"])
	script.loop = true
	var session := DialogueSession.new(script)
	session.start()
	session.next()
	assert_true(session.next(), "loop 脚本末尾应回到开头而不是结束")
	assert_true(session.current() == script.lines[0], "loop 后应回到第一行")
