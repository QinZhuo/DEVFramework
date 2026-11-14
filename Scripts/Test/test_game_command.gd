extends TestCase

## 命令回放的契约：命令是可序列化数据，历史按序可存可读，
## 且旧存档字段（action / index）必须继续能读 —— 否则一次改名就废掉所有旧战报。

func test_command_roundtrip() -> void:
	var cmd := GameCommand.new(&"pick_column", 3, [2, "target"])
	var data := cmd.save_data()
	var back := GameCommand.load_data(data)
	assert_eq(back.type, &"pick_column")
	assert_eq(back.tick, 3)
	assert_eq(back.params, [2, "target"])
	assert_ne(back, cmd, "load_data 应造新对象，不是复用原实例")


## 快照必须是深拷贝：记录之后再改原数组，存档不能跟着变。
func test_save_data_is_a_snapshot() -> void:
	var params: Array = [1]
	var cmd := GameCommand.new(&"x", 0, params)
	var data := cmd.save_data()
	params.append(2)
	assert_eq(data["params"], [1], "save_data 必须与调用方后续修改隔离")


func test_legacy_keys_still_load() -> void:
	var back := GameCommand.load_data({"action": "old_type", "index": 7, "params": [1]})
	assert_eq(back.type, &"old_type", "旧字段 action 应兼容")
	assert_eq(back.tick, 7, "旧字段 index 应兼容")
	assert_eq(back.params, [1])


func test_malformed_entry_yields_empty_command() -> void:
	var back := GameCommand.load_data("not a dict")
	assert_eq(back.type, &"", "非字典输入应得到空命令，由调用方决定兜底")
	assert_eq(back.tick, -1)


func test_history_records_in_order_and_filters_by_tick() -> void:
	var h := CommandHistory.new()
	h.append(GameCommand.new(&"a", 0, [1]))
	h.append(GameCommand.new(&"b", 1, [2]))
	h.append(GameCommand.new(&"c", 1, [3]))

	assert_eq(h.size(), 3)
	assert_eq(h.commands_for(0).size(), 1, "按 tick 过滤")
	assert_eq(h.commands_for(1).size(), 2)
	assert_eq(h.commands_for(1)[0].type, &"b", "同 tick 内保持记录顺序")


func test_history_roundtrip() -> void:
	var h := CommandHistory.new()
	h.append(GameCommand.new(&"a", 0, [1]))
	h.append(GameCommand.new(&"b", 1, [2]))

	var restored := CommandHistory.new()
	restored.load_data(h.save_data())
	assert_eq(restored.size(), 2, "历史应能整体存读")
	assert_eq(restored.commands[1].tick, 1)
	assert_eq(restored.commands[1].params, [2])


func test_history_clear() -> void:
	var h := CommandHistory.new()
	h.append(GameCommand.new(&"a", 0, []))
	h.clear()
	assert_true(h.is_empty(), "clear 后应为空")


## 基类输入源的默认行为：没有输入 = 取消，且**不登记** taken（否则回放比对会凭空多一项）。
func test_base_input_source_cancel_does_not_record() -> void:
	var src := InputSource.new()
	var v := await src.take()
	assert_eq(v, -1, "无输入时应返回 -1")
	assert_eq(src.taken.size(), 0, "取消不应写入 taken")
	assert_false(src.allows_missing_answer(), "实战输入源不允许用默认目标兜底")
