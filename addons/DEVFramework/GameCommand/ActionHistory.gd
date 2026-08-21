@tool
class_name ActionHistory extends RefCounted

## 会话动作日志：按序记录 GameCommand，支持按 tick 过滤与序列化。
## 由实战答案源在动作成功后写入；回放器据此重放。

var actions: Array[GameCommand] = []

func append(action: GameCommand) -> void:
	actions.append(action)

## 删除第一条匹配的动作（用于取消回滚）。predicate 收到 GameCommand 返回是否删除。
## 返回是否有删除
func remove_if(predicate: Callable) -> bool:
	for i in actions.size():
		if predicate.call(actions[i]):
			actions.remove_at(i)
			return true
	return false

## 取指定 tick 的全部动作（保持记录顺序）
func actions_for(tick: int) -> Array[GameCommand]:
	var result: Array[GameCommand] = []
	for action in actions:
		if action.tick == tick:
			result.append(action)
	return result

func clear() -> void:
	actions.clear()

func save_data() -> Array:
	var out := []
	for action in actions:
		out.append(action.save_data())
	return out

func load_data(data) -> void:
	actions.clear()
	if data is Array:
		for entry in data:
			actions.append(GameCommand.load_data(entry))
