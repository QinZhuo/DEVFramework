class_name test_save_tool
extends TestCase

## SaveTool 回归 —— 两类契约, 出错都只会静默丢数据:
##   1) `merge_data` 的跨端合并规则(写错就把好数据覆盖掉);
##   2) 异步保存的健壮性(同路径合并写 / 超时接管后的 flush)。

const PATH_A := "user://test_save_robust_a.json"
const PATH_B := "user://test_save_robust_b.json"


func cleanup() -> void:
	SaveTool.delete_data(PATH_A, SaveTool.Mode.JSON)
	SaveTool.delete_data(PATH_B, SaveTool.Mode.JSON)


# ------------------------------------------------------------
# 1. merge_data
# ------------------------------------------------------------

func test_max_keeps_larger_int() -> void:
	var r: Dictionary = SaveTool.merge_data({n = 5}, {n = 9}, {n = SaveTool.MergeMode.MAX})
	assert_eq(r.n, 9, "MAX 应取更大的整数")
	r = SaveTool.merge_data({n = 9}, {n = 5}, {n = SaveTool.MergeMode.MAX})
	assert_eq(r.n, 9, "MAX 不应让单调量倒退")


func test_max_supports_float() -> void:
	## 回归：旧实现用 int 白名单，float 字段一律被算作 0（时间戳字段踩过）
	var r: Dictionary = SaveTool.merge_data({ts = 100.5}, {ts = 200.25}, {ts = SaveTool.MergeMode.MAX})
	assert_approx(r.ts, 200.25, "MAX 应支持 float")
	assert_eq(typeof(r.ts), TYPE_FLOAT, "float 字段不该被合并成 int")
	r = SaveTool.merge_data({ts = 200.25}, {ts = 100.5}, {ts = SaveTool.MergeMode.MAX})
	assert_approx(r.ts, 200.25, "MAX 不应让 float 倒退")


func test_max_keeps_base_for_non_numeric() -> void:
	## 规则误配到文本/数组上时保留 base：一个坏值不该把好数据清空
	var r: Dictionary = SaveTool.merge_data(
		{name = "a", arr = [1]}, {name = "b", arr = [2, 3]},
		{name = SaveTool.MergeMode.MAX, arr = SaveTool.MergeMode.MAX})
	assert_eq(str(r.name), "a", "非数值字段应保留 base")
	assert_eq((r.arr as Array).size(), 1, "数组字段应保留 base")


# ------------------------------------------------------------
# 2. 异步保存
# ------------------------------------------------------------
## 曾经在这里写 `_save_states[path]` 而不是 `.get(path)` —— `_wait_save_done`
## 超时接管会先 erase, 之后 flush 时字典越界报错, 而报错发生在 await 链里,
## 会把整条保存流程(以及调用它的协程)永久挂住。这里把这几条路钉住。

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
		assert_approx(float(back.get("f", 0.0)), 1.5, "浮点应保真")
		assert_eq(str(back.get("s", "")), "文本", "字符串应保真")
		assert_true(back.get("nested") is Dictionary, "嵌套字典应保真")
