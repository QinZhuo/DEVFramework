class_name SpawnerSystem
extends ECSSystem

## 生成器系统 —— 按间隔批量生成, 每波只 1 次跨语言。
##
## 实测对照(1000 个一批):
##   逐个 `create_entity + add_component`  ≈ 5.8ms
##   `instantiate(prefab, 1000)`           ≈ 0.05~0.3ms
## 这就是"批量入口"存在的理由, 也是本系统的全部价值。
##
## ⚠ 生成器只负责**产**; 回收策略(寿命/出界)在 Projectile/Timer 模块里, 不混在一起。

const EVENT_SPAWNED := &"spawner_wave"

## 每帧需要读写的字段
const FIELDS: Array = [&"prefab", &"interval", &"per_wave", &"max_total", &"spawned", &"elapsed", &"enabled", &"tag"]

var last_spawned := 0


func required_components() -> Array[Script]:
	return [SpawnerComponent]


func read_components() -> Array[Script]:
	return [SpawnerComponent]


func write_components() -> Array[Script]:
	return [SpawnerComponent]


func can_run_parallel() -> bool:
	return false   # instantiate 是结构性变更


func _run(ctx: ECSSystemContext, delta: float) -> void:
	tick(ctx.world, delta)


## 推进一帧。返回本帧生成的总数。
static func tick(world: ECSWorld, delta: float) -> int:
	if world == null or delta <= 0.0:
		return 0
	world.register_component(SpawnerComponent)
	var ents := world.query_entities(SpawnerComponent)
	if ents.is_empty():
		return 0
	var cols: Dictionary = world.columns_of(SpawnerComponent, FIELDS)
	if cols.is_empty():
		return 0
	var c_prefab: PackedInt32Array = cols[&"prefab"]
	var c_interval: PackedFloat32Array = cols[&"interval"]
	var c_wave: PackedInt32Array = cols[&"per_wave"]
	var c_max: PackedInt32Array = cols[&"max_total"]
	var c_spawned: PackedInt32Array = cols[&"spawned"]
	var c_elapsed: PackedFloat32Array = cols[&"elapsed"]
	var c_enabled: PackedByteArray = cols[&"enabled"]
	var c_tag: PackedInt32Array = cols[&"tag"]

	var total := 0
	var touched := false
	for row in ents.size():
		if c_enabled[row] == 0:
			continue
		var interval := maxf(c_interval[row], 0.0001)
		var per := c_wave[row]
		if per <= 0:
			continue
		var pf := c_prefab[row]
		# ⚠ 用 <0 判"未设置": 第一个实体 id 就是 0, 拿 0 当无效值会让生成器永远不出怪(实测踩过)
		if pf < 0 or not world.is_alive(pf):
			continue
		var elapsed := c_elapsed[row] + delta
		var spawned := c_spawned[row]
		var cap := c_max[row]
		var waves := int(floor(elapsed / interval))
		if waves > 0:
			elapsed -= float(waves) * interval
			# 多波同帧(掉帧补偿)也一次算清, 不逐波循环
			var want := waves * per
			if cap > 0:
				want = mini(want, maxi(cap - spawned, 0))
			if want > 0:
				var ids: PackedInt32Array = world.instantiate(pf, want)
				spawned += ids.size()
				total += ids.size()
				# 带上新生成的 id 列表: 调用方通常要给它们各自随机方向/颜色(实测需要)。
				world.emit_event(EVENT_SPAWNED, {
					"spawner": ents[row], "count": ids.size(), "tag": c_tag[row], "ids": ids,
				})
		c_elapsed[row] = elapsed
		c_spawned[row] = spawned
		touched = true
	if touched:
		# 整列写回(1 次跨语言); 只写内部状态两列, 不碰配置列
		world.set_columns_of(SpawnerComponent, {
			&"elapsed": c_elapsed, &"spawned": c_spawned,
		})
	return total


## 便捷: 建一个生成器实体。
static func add(world: ECSWorld, prefab: int, interval: float, per_wave: int,
		max_total := 0, tag := 0) -> int:
	if world == null or prefab < 0:
		return -1
	world.register_component(SpawnerComponent)
	var e := world.create_entity()
	world.add_component(e, SpawnerComponent, {
		&"prefab": prefab, &"interval": interval, &"per_wave": per_wave,
		&"max_total": max_total, &"spawned": 0, &"elapsed": 0.0,
		&"enabled": true, &"tag": tag,
	})
	return e


static func set_enabled(world: ECSWorld, spawner: int, on: bool) -> void:
	if world != null and world.is_alive(spawner):
		world.set_field(spawner, SpawnerComponent, &"enabled", on)
