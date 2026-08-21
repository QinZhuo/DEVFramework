@tool
class_name ScriptedInputSource extends InputSource

## 脚本化输入源：按序弹出预录决策（回放/自动化测试用），绝不触碰任何 UI。
## 与实战日志的 params 决策段一一对应，保证回放确定性。

var answers: Array = []
## 已消费的输入（供校验与调试）
var journal: Array[int] = []

func _init(p_answers: Array = []) -> void:
	answers.assign(p_answers)

func take(_request: Dictionary) -> int:
	if answers.is_empty():
		push_error("ScriptedInputSource: 输入队列已空，动作与记录不匹配")
		return -1
	var value: int = int(answers.pop_front())
	journal.append(value)
	return value