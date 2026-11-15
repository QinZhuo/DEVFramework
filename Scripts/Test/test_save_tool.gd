class_name test_save_tool
extends TestCase

## SaveTool 的健壮性回归。
##
## 背景: 异步保存内部用 `_save_states`(路径 → 保存态) 做同路径合并写。
## 曾经在这里写 `_save_states[path]` 而不是 `.get(path)` —— `_wait_save_done`
## 超时接管会先 erase, 之后 flush 时字典越界报错, 而报错发生在 await 链里,
## 会把整条保存流程(以及调用它的协程)永久挂住。这里把这几条路钉住。

const PATH_A := "user://test_save_robust_a.json"
const PATH_B := "user://test_save_robust_b.json"


func cleanup() -> void:
	SaveTool.delete_data(PATH_A, SaveTool.Mode.JSON)
	SaveTool.delete_data(PATH_B, SaveTool.Mode.JSON)


## 同路径连续保存: 走"合并写"路径, 最终值应是最后一次, 且不报错
func test_concurrent_save_same_path_keeps_last() -> void:
	SaveTool.save_async(PATH_A, {"n": 1}, SaveTool.Mode.JSON)
	SaveTool.save_async(PATH_A, {"n": 2}, SaveTool.Mode.JSON)
	SaveTool.save_async(PATH_A, {"n": 3}, SaveTool.Mode.JSON)
	SaveTool._wait_save_done(PATH_A)
	var data: Variant = SaveTool.load_data(PATH_A, SaveTool.Mode.JSON)
	assert_true(data is Dictionary, "保存后应能读回字典")
	if data is Dictionary:
		assert_eq(int(data.get("n", -1)), 3, "合并写应保留最后一次的值")


## 关键回归: 保存态被外部清掉(等价于 _wait_save_done 超时接管)后再 flush, 不能崩
func test_flush_pending_after_state_lost() -> void:
	SaveTool._save_states.erase(PATH_B)
	var err: Error = await SaveTool._flush_pending(PATH_B, OK)
	assert_true(err == OK, "无待补存时应原样返回上次结果, 实际 %d" % err)


## 两条不同路径互不影响(合并写是按路径分桶的)
func test_different_paths_do_not_interfere() -> void:
	SaveTool.save_async(PATH_A, {"who": "a"}, SaveTool.Mode.JSON)
	SaveTool.save_async(PATH_B, {"who": "b"}, SaveTool.Mode.JSON)
	SaveTool._wait_save_done(PATH_A)
	SaveTool._wait_save_done(PATH_B)
	var a: Variant = SaveTool.load_data(PATH_A, SaveTool.Mode.JSON)
	var b: Variant = SaveTool.load_data(PATH_B, SaveTool.Mode.JSON)
	assert_true(a is Dictionary and a.get("who") == "a", "PATH_A 内容应为 a")
	assert_true(b is Dictionary and b.get("who") == "b", "PATH_B 内容应为 b")


## 保存后再读回, 值类型要能无损往返(数字/字符串/嵌套字典)
func test_roundtrip_preserves_types() -> void:
	var payload := {"i": 42, "f": 1.5, "s": "文本", "nested": {"k": [1, 2, 3]}}
	SaveTool.save_async(PATH_A, payload, SaveTool.Mode.JSON)
	SaveTool._wait_save_done(PATH_A)
	var back: Variant = SaveTool.load_data(PATH_A, SaveTool.Mode.JSON)
	assert_true(back is Dictionary, "应读回字典")
	if back is Dictionary:
		assert_eq(int(back.get("i", -1)), 42)
		assert_true(is_equal_approx(float(back.get("f", 0.0)), 1.5), "浮点应保真")
		assert_eq(str(back.get("s", "")), "文本", "字符串应保真")
		assert_true(back.get("nested") is Dictionary, "嵌套字典应保真")
