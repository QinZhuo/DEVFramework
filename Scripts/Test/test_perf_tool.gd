extends TestCase

## PerfTool 契约回归（纯逻辑，编辑器进程即可）。
##
## 锁定的都是"算错了不会崩、只会给出错误结论"的语义：
## 1) Rolling 定长覆盖与统计（平均/峰值/分位/超阈值计数）；
## 2) stats 的分位取值口径（最近邻，不是插值）；
## 3) bench 只统计 iters 次（warmup 不计入）；
## 4) 历史基线 EMA 落在两次实测之间、suggest_ms 向上取整到秒；
## 5) fmt_ms 的三档文案。

## EMA 用例的临时键: 收尾删掉, 免得两次运行互相污染
const KEY := "test:perf_tool::ema"
## measure_ms 用例的键: 刻意保留 —— 它本身就是"测试方法基线", 删了覆盖率永远不满
const MEASURE_KEY := "test:perf_tool::measure"
const VALUES: Array[float] = [1.0, 2.0, 3.0, 4.0, 5.0]


func cleanup() -> void:
	PerfTool.forget(KEY)
	PerfTool.flush_history()


func test_rolling_is_bounded() -> void:
	var win := PerfTool.Rolling.new(3)
	for v in VALUES:
		win.push(v)
	assert_eq(win.size(), 3, "容量应封顶")
	assert_eq(win.avg(), 4.0, "平均应只算窗口内(3+4+5)/3")
	assert_eq(win.peak(), 5.0, "峰值")
	assert_eq(win.percentile(0.5), 4.0, "P50")
	assert_eq(win.count_over(3.5), 2, "超过 3.5 的有 4、5 两个")
	win.clear()
	assert_true(win.is_empty(), "清空后应为空")


func test_stats_percentiles() -> void:
	var s := PerfTool.stats([5.0, 1.0, 3.0, 2.0, 4.0])
	assert_eq(s["count"], 5, "计数")
	assert_eq(s["avg_ms"], 3.0, "平均")
	assert_eq(s["min_ms"], 1.0, "最小")
	assert_eq(s["max_ms"], 5.0, "最大")
	assert_eq(s["p50_ms"], 3.0, "P50")
	assert_eq(s["p95_ms"], 5.0, "P95 取第 ceil(0.95*5)=5 个, 不是插值")
	assert_eq(PerfTool.stats([])["count"], 0, "空输入不应崩")


func test_bench_excludes_warmup() -> void:
	var hits := [0]
	var r := PerfTool.bench(func() -> void: hits[0] += 1, 4, 2)
	assert_eq(hits[0], 6, "执行次数 = warmup + iters")
	assert_eq(r["count"], 4, "统计样本只含正式轮")
	assert_true(float(r["total_ms"]) >= 0.0, "总耗时应非负")


func test_history_ema_and_suggest() -> void:
	PerfTool.forget(KEY)
	PerfTool.record(KEY, 1000.0)
	assert_eq(float(PerfTool.history(KEY)["ms"]), 1000.0, "首次数值直接采用")
	PerfTool.record(KEY, 2000.0)
	var ema := float(PerfTool.history(KEY)["ms"])
	assert_true(ema > 1000.0 and ema < 2000.0, "EMA 应落在两次实测之间(got=%s)" % str(ema))
	assert_eq(int(PerfTool.history(KEY)["n"]), 2, "次数累计")
	assert_eq(PerfTool.suggest_ms(KEY), 2000, "1000*1.5 向上取整到秒")
	assert_eq(PerfTool.suggest_ms("test:perf_tool::absent"), 0, "无基线返回 0")


func test_history_persists_to_disk() -> void:
	PerfTool.record(KEY, 1234.0)
	PerfTool.flush_history()
	var text := FileAccess.get_file_as_string(PerfTool.HISTORY_PATH)
	assert_true(text.contains(KEY), "基线应已落盘")


func test_fmt_ms() -> void:
	assert_eq(PerfTool.fmt_ms(900.0), "900ms", "毫秒档")
	assert_eq(PerfTool.fmt_ms(12000.0), "12.0s", "秒档")
	assert_eq(PerfTool.fmt_ms(125000.0), "2m05s", "分钟档")


func test_measure_ms_records_baseline() -> void:
	var ms := measure_ms(MEASURE_KEY, func() -> void: pass)
	assert_true(ms >= 0.0, "耗时非负")
	assert_false(PerfTool.history(MEASURE_KEY).is_empty(), "measure_ms 应写入基线")
