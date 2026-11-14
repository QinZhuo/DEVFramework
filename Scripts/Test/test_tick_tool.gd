extends TestCase

## TickTool 的确定性契约：顺序 = 队列内容的纯函数（lane 升序、同 lane FIFO），
## 派发中新增的条目属于**下一 tick**，未接线时立即执行并告警一次。
##
## 回放能否复现完全押在这几条上 —— 顺序一旦取决于"谁先注册"，同输入就会走出不同事件序列。

var _log: Array = []


func cleanup() -> void:
	_log.clear()
	TickTool.reset()


func _push(tag: String) -> Callable:
	return func(): _log.append(tag)


## 驱动一次空 tick，让 TickTool 进入"已接线"状态。
func _drive() -> void:
	TickTool.reset()
	TickTool.tick()


func test_defer_without_driver_runs_immediately() -> void:
	TickTool.reset()
	TickTool.defer(0, _push("a"))
	assert_eq(_log, ["a"], "未接线时应立即执行，不能把等待方挂住")


func test_dispatch_sorted_by_lane() -> void:
	_drive()
	TickTool.defer(2, _push("c"))
	TickTool.defer(0, _push("a"))
	TickTool.defer(1, _push("b"))
	assert_true(_log.is_empty(), "接线后 defer 不应立即执行")
	TickTool.tick()
	assert_eq(_log, ["a", "b", "c"], "应按 lane 升序派发")


func test_same_lane_is_fifo() -> void:
	_drive()
	TickTool.defer(1, _push("first"))
	TickTool.defer(1, _push("second"))
	TickTool.defer(1, _push("third"))
	TickTool.tick()
	assert_eq(_log, ["first", "second", "third"], "同 lane 必须按登记先后")


func test_defer_during_dispatch_waits_next_tick() -> void:
	_drive()
	var nested := func():
		_log.append("outer")
		TickTool.defer(0, _push("inner"))
	TickTool.defer(0, nested)
	TickTool.tick()
	assert_eq(_log, ["outer"], "派发中新登记的条目不能掺进本轮")
	TickTool.tick()
	assert_eq(_log, ["outer", "inner"], "下一 tick 才执行")


func test_clear_drops_pending() -> void:
	_drive()
	TickTool.defer(0, _push("dropped"))
	TickTool.clear()
	TickTool.tick()
	assert_true(_log.is_empty(), "clear 后不应再派发旧条目")


## reset 必须回到"未接线"：新场景忘了接线时仍然要告警并立即执行，而不是静默排队。
func test_reset_returns_to_unwired() -> void:
	_drive()
	TickTool.defer(0, _push("queued"))
	TickTool.reset()
	assert_true(_log.is_empty(), "reset 应丢弃队列")

	TickTool.defer(0, _push("immediate"))
	assert_eq(_log, ["immediate"], "reset 后应恢复立即执行")
