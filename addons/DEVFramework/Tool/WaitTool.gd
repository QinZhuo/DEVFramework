class_name WaitTool

static func wait_all(...signals: Array) -> void:
	if signals.is_empty():
		return

	var remaining := signals.size()
	var triggered = {value = 0}

	for index in signals.size():
		signals[index].connect(func(...args):
			triggered.value += 1
			LogTool.log("等待", "已触发的信号[", index, "]:", signals[index])
		, CONNECT_ONE_SHOT)

	while triggered.value < remaining:
		await Engine.get_main_loop().process_frame
