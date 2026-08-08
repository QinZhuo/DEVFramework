class_name ECSScriptMoveSystem
extends ECSSystem

## 手写脚本层: 移动系统 —— 与 ECSRule 统一查询链 + Callback 执行。
## 与 ECSMoveSystem(原生API层)逻辑完全对称: pos += vel * delta。
## 区别: 用 ctx.for_each(...).each(...) 查询链, 回调内逐实体在 GDScript 循环访问列。

func required_components() -> Array[Script]:
	return [ECSDemoMoveComponent]

func _run(ctx: ECSSystemContext, delta: float) -> void:
	ctx.for_each(ECSDemoMoveComponent).each(_move_cb.bind(delta), [ECSDemoMoveComponent]).execute()


func _move_cb(rows: PackedInt32Array, _comp_rows: Dictionary, w: ECSWorld, delta: float) -> void:
	var pos: PackedVector2Array = w.get_column(ECSDemoMoveComponent, &"pos")
	var vel: PackedVector2Array = w.get_column(ECSDemoMoveComponent, &"vel")
	for r in rows:
		pos[r] += vel[r] * delta
	w.set_column(ECSDemoMoveComponent, &"pos", pos)
