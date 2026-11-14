class_name ResetTool

## 跨场景全局状态复位：切场景 / 回标题 / 换存档时调一次 `ResetTool.all()`。
##
## 框架的全局状态都是各 Tool 上的 static var，不挂在任何节点生命周期上；
## 不清就会带到下一局（UI 栈残留、提示条不消失、音频通道还在响、时间被暂停在 0.1x）。
## 各 `reset()` 都是幂等的，没用到过也安全。

static func all() -> void:
	UITool.reset()
	TipTool.reset()
	TimeTool.reset()
	TickTool.reset()
	PointerTool.reset()
	AudioTool.reset()
	PoolService.clear()
