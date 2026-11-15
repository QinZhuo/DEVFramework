extends TestCase

## 环境帧率基线（必须游戏进程: 依赖真实帧循环与渲染）。
##
## 阈值刻意宽松: 目标不是"卡死 60"这种在低端机/CI 上必闪红的断言, 而是发现
## "掉一个量级"的回归(引入死循环、每帧同步 load、每帧 new 节点之类)。
## 想看具体数字用 perf action=fps, 想要趋势看基线文件里 p50 的历史。

## 平均帧率下限(等效 p50): 30 是 60fps 的一半, 留足机器差异
const MIN_FPS := 30.0
const FRAMES := 120
const WARMUP := 30
const SNAPSHOT_KEYS: Array[String] = ["fps", "frame_ms", "draw_calls", "mem_mb"]


func needs_game_process() -> bool:
	return true


func max_duration_ms() -> int:
	return 20000


func test_frame_rate() -> void:
	# 带 key: p50 帧时间同时写进基线, 下次运行能直接看出"慢了多少", 不必翻日志
	await assert_fps_at_least(MIN_FPS, FRAMES, WARMUP, "test:perf_fps::p50")


func test_snapshot_has_engine_metrics() -> void:
	var s := PerfTool.snapshot()
	for key in SNAPSHOT_KEYS:
		assert_true(s.has(key), "snapshot 缺字段: %s" % key)
	assert_true(float(s["mem_mb"]) > 0.0, "内存占用应大于 0")
