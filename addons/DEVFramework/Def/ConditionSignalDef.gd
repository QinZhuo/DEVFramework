@tool
## 带条件的信号定义
##
## 包装另一个 SignalDef，触发时检查 ConditionDef 条件，仅条件满足时把信号转发给回调
## (常用于计数任务的条件过滤 —— 只统计满足条件的触发)。
## 上下文约定: 条件基于 connect_signal 传入的 data 求值; 信号实参原样转发给回调(任意宽度)。
class_name ConditionSignalDef extends SignalDef


## 被包装的信号定义
@export var signal_def: SignalDef

## 条件（为空时不进行过滤）
@export var condition: ConditionDef

func connect_signal(data, callable: Callable) -> void:
	if not signal_def:
		return
	# bind 追加在参数表末尾: 信号实参在前, [data, callable] 在后 —— _on_signal 据此还原
	signal_def.connect_signal(data, _on_signal.bind(data, callable))

func disconnect_signal(data, callable: Callable) -> void:
	if not signal_def:
		return
	signal_def.disconnect_signal(data, _on_signal.bind(data, callable))

func _on_signal(...args) -> void:
	# args = [信号实参..., data, callable] —— bind 追加在末尾, 零参信号时前段为空
	if args.size() < 2:
		return
	var data = args[args.size() - 2]
	var callback: Callable = args[args.size() - 1]
	if condition and not condition.is_met(data):
		return
	callback.callv(args.slice(0, args.size() - 2))

func _to_string() -> String:
	if signal_def and condition:
		return str(signal_def, " | ", condition)
	if signal_def:
		return str(signal_def)
	if condition:
		return str("[empty] | ", condition)
	return tr(name)
