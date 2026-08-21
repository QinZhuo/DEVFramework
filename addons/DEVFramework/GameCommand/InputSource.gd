@tool
class_name InputSource extends RefCounted

## 决策输入源策略基类。
## 模拟层（效果链）通过 take() 获取一次玩家决策输入，不感知输入来自真实 UI、
## 回放日志还是测试脚本——实现"模拟不知晓界面"的解耦。
## 约定：返回空数组表示取消/无输入；否则返回本次决策的参数数组。

## 获取一次决策输入。request 携带交互描述（类型/范围/图标等）供实现方渲染或匹配
func take(_request: Dictionary) -> Array:
	push_error("InputSource.take 需要子类实现")
	return []
