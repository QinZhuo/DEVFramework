class_name ECSRuleQuery
extends RefCounted

## 统一查询链 —— ECSRule(声明规则)与手写脚本系统共用的"遍历→条件→动作"构建器。
##
## 三种动作模式:
##   1. 标量声明动作(规则层, C++ batch 执行, 最快):
##        for_each(Comp).where(&"x").less_than(50).add(&"x", 10)   # 加
##        ...sub(...) / mul(...) / div(...) / set_value(...)       # 减/乘/除/赋值
##   2. 列间声明动作(规则层, C++ batch 执行, 列与列联动):
##        for_each(Comp).add_col(&"size", Comp, &"hp")             # size += hp
##        ...mul_col(...) / sub_col(...) / div_col(...) / set_from(...)
##        for_each(Comp).clamp_if(&"hp", Comp, &"min_hp", Comp, &"max_hp")
##   3. Callback 动作(手写层, GDScript 执行, 最灵活):
##        for_each(Comp).each(func(rows, data): ...)   # data 预拉列, 自动写回
## 手写层与规则层共享同一查询链: 组件匹配(must/without) + 条件(where) 完全一致。

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


# ---------- 标量声明动作(规则层, C++ batch 执行) ----------

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


# ---------- 列间声明动作(规则层, C++ batch 执行, 列与列联动) ----------

## 动作: 目标字段 += 源字段列(src 组件某字段, 可传 Script 或类名)
func add_col(field: StringName, src, src_field: StringName) -> ECSRuleQuery:
	actions.append({"type": "col", "field": field, "src": src, "src_field": src_field,
			"op": ECSWorld.ColOp.COL_ADD, "factor": 1.0, "addend": 0.0})
	return self

## 动作: 目标字段 -= 源字段列
func sub_col(field: StringName, src, src_field: StringName) -> ECSRuleQuery:
	actions.append({"type": "col", "field": field, "src": src, "src_field": src_field,
			"op": ECSWorld.ColOp.COL_SUB, "factor": 1.0, "addend": 0.0})
	return self

## 动作: 目标字段 *= 源字段列(可标量缩放 factor)
func mul_col(field: StringName, src, src_field: StringName, factor: float = 1.0) -> ECSRuleQuery:
	actions.append({"type": "col", "field": field, "src": src, "src_field": src_field,
			"op": ECSWorld.ColOp.COL_MUL, "factor": factor, "addend": 0.0})
	return self

## 动作: 目标字段 /= 源字段列(除零跳过)
func div_col(field: StringName, src, src_field: StringName, factor: float = 1.0) -> ECSRuleQuery:
	actions.append({"type": "col", "field": field, "src": src, "src_field": src_field,
			"op": ECSWorld.ColOp.COL_DIV, "factor": factor, "addend": 0.0})
	return self

## 动作: 目标字段 = 源字段列(可标量缩放)。例: size = hp * 0.08 + 8
func set_from(field: StringName, src, src_field: StringName, factor: float = 1.0, addend: float = 0.0) -> ECSRuleQuery:
	actions.append({"type": "col", "field": field, "src": src, "src_field": src_field,
			"op": ECSWorld.ColOp.COL_SET, "factor": factor, "addend": addend})
	return self

## 动作: 仅满足条件的实体 目标字段 = clamp(目标字段, min, max)(列间边界)
func clamp_if(field: StringName, min_comp, min_field: StringName,
		max_comp, max_field: StringName) -> ECSRuleQuery:
	actions.append({"type": "clamp", "field": field,
			"min_comp": min_comp, "min_field": min_field,
			"max_comp": max_comp, "max_field": max_field})
	return self


# ---------- Callback 动作(手写层, GDScript 执行) ----------

## 动作: 用 GDScript Callback 自定义遍历逻辑。
## 两种参数模式:
##   A. each(cb, comps: Array) —— 回调签名 cb(rows, comp_rows, world)
##      comp_rows 是各组件对齐行号; 回调内 world.get_column 取列 → 改 → set_column 写回。
##   B. each(cb, fields: Dictionary) —— 回调签名 cb(rows, data), 推荐:
##      fields = {组件: [字段...]}; 框架回调前 get_columns 预拉全部列(1 次跨语言),
##      回调内 data[组件类名][字段名] 直接读写(零跨语言), 回调后框架自动 set_columns 写回。
##      rows 是满足条件的 anchor 行号; data 里列按各组件 dense 行号索引。
## 例: ctx.for_each(BattleCell).each(func(rows, data):
##         var hp: PackedFloat32Array = data["BattleCell"]["hp"]
##         for r in rows: hp[r] -= 1
##     , {BattleCell: [&"hp"]})
func each(cb: Callable, fields = {}) -> ECSRuleQuery:
	if fields is Dictionary and not fields.is_empty():
		actions.append({"type": "call_fields", "callable": cb, "fields": fields})
	else:
		var comps: Array = fields if fields is Array else []
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


func _comp_name(c) -> StringName:
	if c is Script:
		var n: StringName = world.component_name(c)
		if n != &"":
			return n
	return StringName(str(c))


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
			"col":
				total += world.batch_apply_col(anchor, must, anchor, act.field,
						act.src, act.src_field, act.op, act.factor, act.addend, conditions)
			"clamp":
				total += world.batch_clamp_where(anchor, must, anchor, act.field,
						act.min_comp, act.min_field, act.max_comp, act.max_field, conditions)
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
					comp_rows[_comp_name(act.comps[i])] = aligned[i + 1]
				total += rows.size()
				act.callable.call(rows, comp_rows, world)
			"call_fields":
				var comps: Array = []
				for c in act.fields:
					comps.append(c)
				var faligned: Array = world.query_aligned_where(anchor, must, without,
						conditions, comps)
				if faligned.is_empty():
					continue
				var frows: PackedInt32Array = faligned[0]
				if frows.is_empty():
					continue
				var norm := []
				for c in act.fields:
					norm.append({"comp": _comp_name(c), "fields": act.fields[c]})
				var data: Dictionary = world.get_columns(norm)
				total += frows.size()
				act.callable.call(frows, data)
				# 自动写回: 框架保证回调内对 data 的改动生效
				var write_back := {}
				for c in act.fields:
					var cn := _comp_name(c)
					if data.has(cn):
						write_back[cn] = data[cn]
				world.set_columns(write_back)
	return total
