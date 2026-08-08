class_name ECSRuleQuery
extends RefCounted

## 统一查询链 —— ECSRule(声明规则)与手写脚本系统共用的"遍历→条件→动作"构建器。
##
## 两种动作模式:
##   1. 声明动作(规则层, C++ batch 执行, 最快):
##        for_each(Comp).where(&"x").less_than(50).add(&"x", 10)   # 加
##        ...sub(...) / mul(...) / div(...) / set_value(...)       # 减/乘/除/赋值
##   2. Callback 动作(手写层, GDScript 执行, 最灵活):
##        for_each(Comp).call(func(rows, comp_rows, world):
##            var col = world.get_column(Comp, &"x")
##            for r in rows: col[r] -= 1
##        , [Comp])
##      rows 是满足条件的 anchor 行号; comp_rows 是各组件对齐行号(与 rows 一一对应),
##      回调内用 world.get_column 取列后按行号读写(共享引用, 直接改即可)。
##
## 手写层与规则层共享同一查询链: 组件匹配(must/without) + 条件(where) 完全一致,
## 区别仅在"动作"——规则用 C++ 批量算子, 手写用 GDScript Callback。

var world: ECSWorld
var anchor  # 锚组件(Script 或类名)
var must: Array = []       # 必须同时拥有的组件
var without: Array = []    # 不得拥有的组件
var conditions: Array = []   # [{comp, field, op, value}]
var actions: Array = []      # [{type, ...}]
var _executed := false


func _init(p_world: ECSWorld = null, p_anchor = null) -> void:
	world = p_world
	anchor = p_anchor


## 由 ECSRuleContext / ECSSystemContext.for_each 实例化后调用。
func _init_rule(p_world: ECSWorld, p_anchor, p_must: Array = [], p_without: Array = []) -> ECSRuleQuery:
	world = p_world
	anchor = p_anchor
	must = p_must
	without = p_without
	return self


# ---------- 条件(可多个, AND 语义) ----------

## 指定条件字段, 后续用 less_than / greater_than 等比较
func where(field: StringName) -> ECSRuleCond:
	return ECSRuleCond.new(self, field)

## 直接指定完整条件(等价 where().xxx())
func where_cond(field: StringName, op: int, value) -> ECSRuleQuery:
	conditions.append({"comp": anchor, "field": field, "op": op, "value": value})
	return self


# ---------- 声明动作(规则层, C++ batch 执行) ----------

## 动作: 给字段加值
func add(field: StringName, amount) -> ECSRuleQuery:
	actions.append({"type": "add", "field": field, "amount": amount})
	return self

## 动作: 给字段减量(等价 add(-amount))
func sub(field: StringName, amount) -> ECSRuleQuery:
	actions.append({"type": "sub", "field": field, "amount": amount})
	return self

## 动作: 给字段乘系数
func mul(field: StringName, factor) -> ECSRuleQuery:
	actions.append({"type": "mul", "field": field, "factor": factor})
	return self

## 动作: 给字段除以除数
func div(field: StringName, divisor) -> ECSRuleQuery:
	actions.append({"type": "div", "field": field, "divisor": divisor})
	return self

## 动作: 给字段设置值
func set_value(field: StringName, value) -> ECSRuleQuery:
	actions.append({"type": "set", "field": field, "value": value})
	return self


# ---------- Callback 动作(手写层, GDScript 执行) ----------

## 动作: 用 GDScript Callback 自定义遍历逻辑。
## cb(rows: PackedInt32Array, comp_rows: Dictionary, world: ECSWorld)
##   rows:      满足条件的 anchor 组件行号(已按 must/without/where 过滤)
##   comp_rows: {组件类名: PackedInt32Array} —— 每个 comps 组件与 rows 对齐的行号
##   world:     ECSWorld(回调内 get_column 取列 → 修改 → set_column 写回)
## comps: 需要对齐行号的组件列表(回调内要访问其列的组件, 可传 Script 或类名)
## 注意: get_column 返回的列是写时复制(COW)副本, 修改后必须 world.set_column 写回
##       (PackedArray 原地写不回到原生存储)。热路径请优先用 add/sub/mul/div(C++ batch)。
func each(cb: Callable, comps: Array = []) -> ECSRuleQuery:
	actions.append({"type": "call", "callable": cb, "comps": comps})
	return self


## 执行规则(返回处理实体数)。未显式调用时链尾自动执行。
func execute() -> int:
	if _executed:
		return _last_count
	_executed = true
	_last_count = _run()
	return _last_count


var _last_count := 0


func _run() -> int:
	if world == null:
		return 0
	var total := 0
	for act in actions:
		match act.type:
			"add":
				total += world.batch_add_value_if(anchor, must, anchor, act.field,
						act.amount, conditions)
			"sub":
				total += world.batch_apply_if(anchor, must, anchor, act.field,
						ECSWorld.BatchOp.ADD_VALUE, 0.0, -float(act.amount), conditions)
			"mul":
				total += world.batch_apply_if(anchor, must, anchor, act.field,
						ECSWorld.BatchOp.MULTIPLY_ADD, float(act.factor), 0.0, conditions)
			"div":
				total += world.batch_apply_if(anchor, must, anchor, act.field,
						ECSWorld.BatchOp.MULTIPLY_ADD, 1.0 / float(act.divisor), 0.0, conditions)
			"set":
				total += world.batch_set_value_if(anchor, must, anchor, act.field,
						act.value, conditions)
			"call":
				var aligned: Array = world.query_aligned_where(anchor, must, without,
						conditions, act.comps)
				if aligned.is_empty():
					continue
				var rows: PackedInt32Array = aligned[0]
				if rows.is_empty():
					continue
				var comp_rows := {}
				for i in act.comps.size():
					var cn := world.component_name(act.comps[i])
					if cn == &"":
						cn = StringName(str(act.comps[i]))
					comp_rows[cn] = aligned[i + 1]
				total += rows.size()
				act.callable.call(rows, comp_rows, world)
	return total
