class_name GoapAction extends Entity

## GOAP 行动实例 — 由 GoapActionDef 通过 create_entity() 创建。
## 每次规划都会创建一批新的行动实例（RefCounted，轻量），
## 生命周期由 GoapAgent 管理。

var def: GoapActionDef
var _performing := false


static func create(action_def: GoapActionDef) -> GoapAction:
	return action_def.create_entity()


## 运行时检查：前提是否满足 + 附加条件（condition）是否通过
func can_run(world_state: GoapWorldState, agent: GoapAgent) -> bool:
	if not world_state.matches(def.preconditions):
		return false
	if def.condition:
		return def.condition.is_met(agent)
	return true


func get_cost() -> float:
	return def.cost


## 触发执行。
## 无 perform_method      → 纯配置行动，直接完成并应用 effects
## perform_method 返回 bool → 同步完成 / 同步失败（方法应声明 -> bool）
## perform_method 返回 null → 异步，等待 agent.notify_action_finished(success)
##                            （异步方法请声明 -> Variant 或不声明返回类型）
func execute(agent: GoapAgent) -> void:
	_performing = true
	if def.perform_method.is_empty():
		agent.notify_action_finished(true)
		return
	var result = agent.call(def.perform_method, self)
	if result is bool:
		agent.notify_action_finished(result)


## 行动成功后，把 effects 应用到世界状态
func apply_effects(world_state: GoapWorldState) -> void:
	world_state.apply(def.effects)
