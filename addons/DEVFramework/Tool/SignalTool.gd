class_name SignalTool

static func wait_all(...signals: Array) -> void:
	if signals.is_empty():
		return

	var remaining := signals.size()
	var triggered = {value = 0}

	for index in signals.size():
		signals[index].connect(func(...args):
			triggered.value += 1
			LogTool.log("信号", "已触发的信号[", index + 1, '/', remaining, "]:", signals[index])
		, CONNECT_ONE_SHOT)

	while triggered.value < remaining:
		await Engine.get_main_loop().process_frame

static func wait_emit(s: Signal, ...args) -> void:
	var conns := s.get_connections()
	if conns.is_empty():
		return
	var timer := LogTool.timer("信号", str("同步信号 ", s.get_object().get_class(), ".", s.get_name()))
	for conn in conns:
		var cb: Callable = conn.callable
		var flags: int = conn.flags
		await cb.callv(args)
		if flags & CONNECT_ONE_SHOT:
			s.disconnect(cb)
	timer.stop()
