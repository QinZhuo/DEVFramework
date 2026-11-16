class_name GameTimer extends RefCounted

## 可被外部推进的轻量计时器（由宿主的物理 tick 驱动 ⇒ 计时基准是物理 tick，与帧率无关）。
##
## ===== 本模块有两种实现, 同目录并存, 按规模选 =====
##   · 本文件(GameTimer): **OOP 参考实现**。每个对象一个实例, 宿主自己持有 Array[GameTimer] 并逐个推进。
##     适合: 几十个计时器、事件驱动、需要"每个计时器一个独立对象"(比如挂 signal / 带自定义状态)。
##     成本: 逐个 advance ≈ 0.19~0.33ms / 1000 个(实测), 与总数线性相关, 且**没有到期也照付**。
##   · TimerSystem + TimerComponent: **ECS 实现**。计时器是实体, 整列推进 + 原生条件过滤。
##     适合: 上千个同类计时器(冷却/DoT/减益), 或"绝大多数帧没有到期"的场景。
##     成本: 空闲推进 0.060ms / 2000 个(与总数弱相关), 到期按个数计费(≈1.35µs/个)。
##
## 对照数据见 Scripts/Test/test_ecs_timer.gd 的 test_oop_vs_ecs_speed(它同时是回归闸门)。
## 迁移: 同一套语义(到期发一次信号/事件), 差别是 ECS 版走 world 事件(&"timer_expired"),
##      并且 repeat 语义用 TimerComponent.RepeatMode 显式表达(不再靠 -1 魔法值)。

signal timeout(not_stop: bool)

var time: float
var cur_time := 0.0
## 是否已发射（幂等：防止重复派发）
var emitted := false
## 最近一次推进时给入的次序 —— 供 `stop()` 复用（保证"取消"与"到期"落在同一个顺序里）
var _order := 0


func _init(init_time := 0.0):
	time = init_time


## 推进；到期时把"发射"按 `order_key` 排进本 tick 的队列。
func advance(delta: float, order_key := 0) -> void:
	_order = order_key
	if emitted or cur_time >= time:
		return
	cur_time += delta
	if cur_time >= time:
		emitted = true
		TickTool.defer(order_key, _emit_true)


## 提前停止（未到期才生效）：同样进队列，"取消"也落在同一个顺序里
func stop() -> void:
	if emitted or cur_time >= time:
		return
	emitted = true
	TickTool.defer(_order, _emit_false)


func _emit_true() -> void:
	timeout.emit(true)


func _emit_false() -> void:
	timeout.emit(false)
