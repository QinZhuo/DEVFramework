extends TestCase

## 事件契约(双缓冲): 写缓冲 `_event_queues` ← 系统内 emit; 帧末 `_dispatch_events` 快照 →
## 读缓冲 `_event_prev` + 广播订阅者。因此:
##   ① 未 tick 前取不到(take_events 只读已派发批次);
##   ② 派发后取一次即没了;
##   ③ 订阅者(广播)在帧末收到, 且与"取走"互不影响 —— 两种消费方式并存。
## 之前没有事件测试, 这套语义一改就可能悄悄破坏(实测"整批 0 项"那种坑)。

func test_event_double_buffer_and_take_once() -> void:
	var w := ECSWorld.new(false)
	var got: Array = []
	w.on_event(&"ping", func(p): got.append(p))

	w.emit_event(&"ping", 42)
	assert_eq(w.take_events(&"ping").size(), 0, "未派发前取不到(还在写缓冲)")
	assert_true(w.has_pending_events(&"ping"), "待派发事件应可见")

	w.tick(1.0 / 60.0)
	assert_eq(got.size(), 1, "订阅者应在帧末收到")
	assert_eq(int(got[0]), 42, "载荷原样")

	var taken := w.take_events(&"ping")
	assert_eq(taken.size(), 1, "派发后可被取走一次")
	assert_eq(int(taken[0]), 42, "取走的载荷一致")
	assert_eq(w.take_events(&"ping").size(), 0, "取一次即没了(不再重复消费)")
	assert_false(w.has_pending_events(&"ping"), "派发后写缓冲已清空")


func test_event_batch_order_and_independence() -> void:
	var w := ECSWorld.new(false)
	var got: Array = []
	w.on_event(&"n", func(p): got.append(p))
	w.emit_event(&"n", 1)
	w.emit_event(&"n", 2)
	w.emit_event(&"n", 3)
	w.tick(1.0 / 60.0)
	assert_eq(got.size(), 3, "同帧多条按投递顺序派发")
	assert_eq(int(got[0]), 1, "顺序 1")
	assert_eq(int(got[2]), 3, "顺序 3")

	var taken := w.take_events(&"n")
	assert_eq(taken.size(), 3, "广播之后仍可取走整批")
	assert_eq(got.size(), 3, "取走不影响广播(两者独立)")
	assert_eq(w.take_events(&"n").size(), 0, "只能取一次")


## 下一帧没有新事件时, 读缓冲会被空快照替换(旧的未取事件不跨帧堆积)。
func test_event_buffer_does_not_accumulate_across_frames() -> void:
	var w := ECSWorld.new(false)
	w.emit_event(&"x", 1)
	w.tick(1.0 / 60.0)
	assert_eq(w.take_events(&"x").size(), 1, "第一帧可取")
	w.tick(1.0 / 60.0)
	w.tick(1.0 / 60.0)
	assert_eq(w.take_events(&"x").size(), 0, "后续帧不应复活旧事件")
