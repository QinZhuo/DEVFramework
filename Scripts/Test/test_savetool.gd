extends TestCase

## `SaveTool.merge_data` 的合并契约：跨端合并全靠它，规则写错只会静默丢数据。


func test_max_keeps_larger_int() -> void:
	var r: Dictionary = SaveTool.merge_data({n = 5}, {n = 9}, {n = SaveTool.MergeMode.MAX})
	assert_eq(r.n, 9, "MAX 应取更大的整数")
	r = SaveTool.merge_data({n = 9}, {n = 5}, {n = SaveTool.MergeMode.MAX})
	assert_eq(r.n, 9, "MAX 不应让单调量倒退")


func test_max_supports_float() -> void:
	## 回归：旧实现用 int 白名单，float 字段一律被算作 0（时间戳字段踩过）
	var r: Dictionary = SaveTool.merge_data({ts = 100.5}, {ts = 200.25}, {ts = SaveTool.MergeMode.MAX})
	assert_eq(r.ts, 200.25, "MAX 应支持 float")
	assert_eq(typeof(r.ts), TYPE_FLOAT, "float 字段不该被合并成 int")
	r = SaveTool.merge_data({ts = 200.25}, {ts = 100.5}, {ts = SaveTool.MergeMode.MAX})
	assert_eq(r.ts, 200.25, "MAX 不应让 float 倒退")


func test_max_keeps_base_for_non_numeric() -> void:
	## 规则误配到文本/数组上时保留 base：一个坏值不该把好数据清空
	var r: Dictionary = SaveTool.merge_data(
		{name = "a", arr = [1]}, {name = "b", arr = [2, 3]},
		{name = SaveTool.MergeMode.MAX, arr = SaveTool.MergeMode.MAX})
	assert_eq(str(r.name), "a", "非数值字段应保留 base")
	assert_eq((r.arr as Array).size(), 1, "数组字段应保留 base")
