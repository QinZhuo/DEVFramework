class_name TestCase extends RefCounted

## 测试用例基类(框架仅提供断言基建, 具体用例由项目在 Scripts/Test/ 下编写)。

var _failures: Array = []
var _current_method := ""


## 该用例是否**必须**在游戏进程里跑(依赖项目单例 / 场景树 / 真实时间轴)。
##   · `run_tests(process=editor)` 不会跑它, 而是列为 **skipped 并写进结果文本**
##   · 由 `run_tests(process=game)`(MCP, 游戏进程内) 或 headless `--game` 实际执行。
func needs_game_process() -> bool:
	return false


func _fail(msg: String) -> void:
	_failures.append("%s: %s" % [_current_method, msg])


func assert_true(cond: bool, msg := "") -> void:
	if not cond:
		_fail(msg if msg != "" else "期望为 true")


func assert_false(cond: bool, msg := "") -> void:
	if cond:
		_fail(msg if msg != "" else "期望为 false")


func assert_eq(got, want, msg := "") -> void:
	if got != want:
		_fail("%s (got=%s want=%s)" % [msg if msg != "" else "值不相等", str(got), str(want)])


func assert_ne(got, not_want, msg := "") -> void:
	if got == not_want:
		_fail("%s (got=%s 不应等于 %s)" % [msg if msg != "" else "值不应相等", str(got), str(not_want)])


## 断言一段逻辑的耗时上限(毫秒)。阈值要留足机器差异余量, 否则 CI 上必闪红。
func assert_under_ms(limit_ms: float, action: Callable, msg := "") -> void:
	var ms := PerfTool.measure(action)
	if ms > limit_ms:
		_fail("%s耗时 %.2fms > 上限 %.2fms" % [_prefix(msg), ms, limit_ms])


## 测一段逻辑的耗时并写入历史基线(不判失败), 返回毫秒。
## 基线可以在多次运行间对比, 比"打印一行日志"更有用。
func measure_ms(key: String, action: Callable) -> float:
	var ms := PerfTool.measure(action)
	PerfTool.record(key, ms)
	return ms


## 采样真实帧率(需游戏进程: 会 await 若干帧)。返回 PerfTool.sample_frames 的结果。
func measure_fps(frames := 120, warmup := 30) -> Dictionary:
	return await PerfTool.sample_frames(frames, warmup)


## 断言平均帧率下限(p50 反推的等效帧率, 比瞬时 fps 更能代表稳定性)。
## [param key] 非空时把 p50 帧时间记入历史基线, 下次运行可直接对比趋势。
func assert_fps_at_least(min_fps: float, frames := 120, warmup := 30, key := "") -> void:
	var r: Dictionary = await measure_fps(frames, warmup)
	if r.has("error"):
		_fail(str(r["error"]))
		return
	if key != "":
		PerfTool.record(key, float(r.get("p50_ms", 0.0)))
	var fps := float(r.get("fps_p50", 0.0))
	if fps < min_fps:
		_fail("帧率 %.1f < 下限 %.1f (p95 帧时间 %.1fms, 卡顿 %d 次, 绘制 %d)" % [
			fps, min_fps, float(r.get("p95_ms", 0.0)),
			int(r.get("stutter", 0)), int(r.get("draw_calls", 0))])


func _prefix(msg: String) -> String:
	return "%s " % msg if msg != "" else ""


## 用例级收尾钩子。runner 在**每个 test_ 方法之后无条件调用**（不论成败）。
## 存在的理由：会写持久化状态（存档/配置）的用例必须收尾还原，而**手动收尾只覆盖
## 约定：**必须幂等** —— 手动收尾已做过的用例，这里是空操作（靠收尾函数自身的状态判断）。
func cleanup() -> void:
	pass


## 该用例**预期**的最长运行时间（毫秒）；<=0 表示不限。
## 实测用时超过声明值时，在结果里列一条 **SLOW**（不算失败），方便发现"某次改动让它悄悄变慢"。
func max_duration_ms() -> int:
	return 0
