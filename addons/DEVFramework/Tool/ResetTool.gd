class_name ResetTool

## 跨场景全局状态复位：切场景 / 回标题 / 换存档时调一次 `ResetTool.all()`。

static func all() -> void:
	UITool.reset()
	TipTool.reset()
	TimeTool.reset()
	TickTool.reset()
	PointerTool.reset()
	AudioTool.reset()
	PoolService.clear()
