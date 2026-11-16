class_name ProjectileSystem
extends ECSSystem

## 投射物系统 —— 位置积分 + 寿命回收。
##
## 每帧固定 4 次跨语言(与子弹数无关):
##   ① `batch_apply(life -= delta)`  原生列减法
##   ② `columns_of([pos, vel])`      整列读
##   ③ `set_columns_of({pos})`       整列写回
##   ④ 到期回收: 原生条件过滤 + `cmd_destroy_many` 一次销毁
## 中间的位置积分在 GDScript 里跑, 但只是纯 PackedVector3Array 运算(约 0.1µs/颗),
## 真正贵的是跨语言边界, 所以把它压到常数次。
##
## 实测(20000 颗, 每帧): 见 test_ecs_modules 的预算闸门。

const EVENT_EXPIRED := &"projectile_expired"

## 每帧推进需要读取的字段
const FIELDS: Array = [&"pos", &"vel"]

var last_integrated := 0
var last_expired := 0


func required_components() -> Array[Script]:
	return [ProjectileComponent]


func read_components() -> Array[Script]:
	return [ProjectileComponent]


func write_components() -> Array[Script]:
	return [ProjectileComponent]


## 会销毁到期实体(结构性变更) → 不能与其它系统并行。
func can_run_parallel() -> bool:
	return false


func _run(ctx: ECSSystemContext, delta: float) -> void:
	tick(ctx.world, delta)


## 推进一帧。返回 {integrated, expired}。
static func tick(world: ECSWorld, delta: float) -> Dictionary:
	var out := {"integrated": 0, "expired": 0}
	if world == null or delta <= 0.0:
		return out
	world.register_component(ProjectileComponent)

	# ① 寿命: 原生整列减(1 次跨语言)
	world.batch_apply(ProjectileComponent, [], ProjectileComponent, &"life", 0, 1.0, -delta)

	# ②③ 位置积分: 整列读 → 本地算 → 整列写回(2 次跨语言)
	var cols: Dictionary = world.columns_of(ProjectileComponent, FIELDS)
	if cols.is_empty():
		# 没有投射物(或组件未注册) → 仍要处理"上一帧留下的到期项"
		_collect_and_reap(world, out)
		return out
	var pos: PackedVector3Array = cols[&"pos"]
	var vel: PackedVector3Array = cols[&"vel"]
	var n := mini(pos.size(), vel.size())
	for i in n:
		pos[i] = pos[i] + vel[i] * delta
	if n > 0:
		world.set_columns_of(ProjectileComponent, {&"pos": pos})
	out["integrated"] = n

	_collect_and_reap(world, out)
	return out


## 到期回收: 原生条件过滤(life <= 0) → 批量销毁。
static func _collect_and_reap(world: ECSWorld, out: Dictionary) -> void:
	# ⚠ lambda 按值捕获局部变量, 用 Array 当接收槽(踩过)
	var sink: Array = []
	ECSQuery.new(world, ProjectileComponent) \
			.where(&"life").less_or_equal(0.0) \
			.process(func(rows: PackedInt32Array, _c: Dictionary, _w) -> void:
				sink.append(rows)).execute()
	if sink.is_empty():
		return
	var rows: PackedInt32Array = sink[0]
	if rows.is_empty():
		return
	# 行号 → 实体 id(整取, 不逐行跨语言)
	var ents := world.query_entities(ProjectileComponent)
	var to_kill := PackedInt32Array()
	to_kill.resize(rows.size())
	for i in rows.size():
		var row := int(rows[i])
		if row >= 0 and row < ents.size():
			to_kill[i] = ents[row]
		else:
			to_kill[i] = -1
	# 到期事件: 带上**销毁前**的位置与 tag(命中特效/飘字要用; 销毁后就读不到了)。
	# 到期数每帧很少(几个~几十), 所以这里逐条 get_field 是划算的。
	for e in to_kill:
		if e < 0:
			continue
		world.emit_event(EVENT_EXPIRED, {
			"entity": e,
			"pos": world.get_field(e, ProjectileComponent, &"pos"),
			"tag": world.get_field(e, ProjectileComponent, &"tag"),
		})
	world.cmd_destroy_many(to_kill)
	world.cmd_flush()
	out["expired"] = to_kill.size()


## 便捷: 造一颗子弹(pos/vel/life/tag 一次写全, 走 add_component 单次跨语言)。
## 大批量请用 prefab + `instantiate`(一次建 N 个), 别在循环里调它。
static func spawn(world: ECSWorld, pos: Vector3, vel: Vector3, life: float, tag := 0) -> int:
	if world == null:
		return -1
	world.register_component(ProjectileComponent)
	var e := world.create_entity()
	world.add_component(e, ProjectileComponent, {
		&"pos": pos, &"vel": vel, &"life": life, &"tag": tag,
	})
	return e
