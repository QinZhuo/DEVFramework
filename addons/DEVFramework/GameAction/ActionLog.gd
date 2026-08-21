@tool
class_name ActionLog extends RefCounted

## 会话动作日志：按序记录 GameAction，支持按 index 过滤与序列化。
## 由实战答案源在动作成功后写入；回放器据此重放。命名与 FightLog 呼应。

var actions: Array[GameAction] = []

func append(action: GameAction) -> void:
	actions.append(action)

## 删除第一条匹配的动作（用于取消回滚）。predicate 收到 GameAction 返回是否删除。
## 返回是否有删除
func remove_if(predicate: Callable) -> bool:
	for i in actions.size():
		if predicate.call(actions[i]):
			actions.remove_at(i)
			return true
	return false

## 取指定 index 的全部动作（保持记录顺序）
func actions_for(index: int) -> Array[GameAction]:
	var result: Array[GameAction] = []
	for action in actions:
		if action.index == index:
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
			actions.append(GameAction.load_data(entry))