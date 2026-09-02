## 信号任务实体 — 由 SignalTaskDef 驱动，任一信号触发即完成。
class_name SignalTask extends Task

func activate(data) -> void:
	super(data)
	if is_completed:
		return
	_connect_signals(data)

func deactivate() -> void:
	# 先断信号，再调父类清理 _handler
	if _handler.is_valid() and def is SignalTaskDef:
		var task_def := def as SignalTaskDef
		for s in task_def.signals:
			if s:
				s.disconnect_signal(_data, _handler)
	super()

func _connect_signals(data) -> void:
	var task_def := def as SignalTaskDef
	if not task_def or task_def.signals.is_empty():
		return
	# 兼容任意参数宽度的信号：无参(如 Button.pressed)、单参(自定义 data 回调)、
	# 或多参(如 card_levelup_requested(card, options)) 均可，多余实参由 rest 兜底收集。
	_handler = func(_signal_data = null, ..._extra):
		if is_completed:
			return
		complete()
	for s in task_def.signals:
		if s:
			s.connect_signal(data, _handler)
