extends TestCase

## 示例模块（`Scripts/Demo/ECS/`，项目侧代码，不是框架 API）的语义与性能对照。
##
## 这三个模块演示的是**怎么用 ECS 核心能力**：
##   · Projectile: 整列读 → 本地算 → 整列写回（4 次跨语言/帧，与子弹数无关）
##   · Spawner:    `instantiate(prefab, n)` 批量生成 vs 逐个 create+add_component
##   · PopupText:  节点池复用 + 数据/视图分离（数据侧可在 headless 跑）

const N_BATCH := 500


func _bullets(n: int, life := 10.0) -> ECSWorld:
	var w := ECSWorld.new(false)
	w.register_component(ProjectileComponent)
	var pf := w.create_prefab()
	w.prefab_add(pf, ProjectileComponent, {
		&"pos": Vector3.ZERO, &"vel": Vector3(1, 0, 0), &"life": life, &"tag": 0,
	})
	w.instantiate(pf, n)
	return w


## 位置积分与到期回收: 一次 tick 完成, 到期者整批销毁。
func test_projectile_integrate_and_expire() -> void:
	var w := _bullets(100, 0.5)
	var r: Dictionary = ProjectileSystem.tick(w, 0.25)
	assert_eq(int(r["integrated"]), 100, "应积分 100 颗")
	assert_eq(int(r["expired"]), 0, "0.25s 不该到期")
	var pos: PackedVector3Array = w.get_column(ProjectileComponent, &"pos")
	assert_approx(pos[0].x, 0.25, "pos += vel * dt")

	var r2: Dictionary = ProjectileSystem.tick(w, 0.5)
	assert_eq(int(r2["expired"]), 100, "0.5s 后应全部到期")
	assert_eq(w.count(ProjectileComponent), 0, "到期实体应被销毁")


## 生成器: 按间隔出波, 掉帧时多波一次结算; 受 max_total 限制。
func test_spawner_waves_and_cap() -> void:
	var w := ECSWorld.new(false)
	w.register_component(ProjectileComponent)
	w.register_component(SpawnerComponent)
	var pf := w.create_prefab()
	w.prefab_add(pf, ProjectileComponent, {
		&"pos": Vector3.ZERO, &"vel": Vector3(0, 0, 1), &"life": 5.0,
	})
	SpawnerSystem.add(w, pf, 0.1, 50, 120)
	assert_eq(SpawnerSystem.tick(w, 0.25), 100, "0.25s 应出 2 波 × 50")
	assert_eq(w.count(ProjectileComponent), 100, "实体数")
	assert_eq(SpawnerSystem.tick(w, 1.0), 20, "max_total=120 → 只补 20")
	assert_eq(w.count(ProjectileComponent), 120, "封顶后不再生成")


## 生成性能: 批量 instantiate 必须显著快于逐个 create + add_component。
func test_spawn_batch_vs_loop() -> void:
	var w := ECSWorld.new(false)
	w.register_component(ProjectileComponent)
	var pf := w.create_prefab()
	w.prefab_add(pf, ProjectileComponent, {
		&"pos": Vector3.ZERO, &"vel": Vector3.ZERO, &"life": 5.0,
	})
	var batch := PerfTool.bench(func() -> void: w.instantiate(pf, N_BATCH), 4, 1)
	var loop := PerfTool.bench(func() -> void:
		for i in N_BATCH:
			var e := w.create_entity()
			w.add_component(e, ProjectileComponent, {&"pos": Vector3.ZERO})
	, 4, 1)
	assert_true(batch.p50_ms < loop.p50_ms * 0.5,
			"批量生成应至少快 2×: batch=%.3fms loop=%.3fms(%d 个)" % [
				batch.p50_ms, loop.p50_ms, N_BATCH])


## 飘字: 池复用(不偷偷扩容) + 数据侧到期回收。
func test_popup_pool_and_recycle() -> void:
	var w := ECSWorld.new(false)
	w.register_component(PopupTextComponent)
	var root := Node3D.new()
	var sys := PopupTextSystem.new()
	sys.bind_pool(root, 8)

	for i in 10:
		var e := w.create_entity()
		w.add_component(e, PopupTextComponent, {
			&"pos": Vector3(float(i), 0, 0), &"life": 1.0, &"ttl": 1.0,
			&"rise": 2.0, &"text": "12", &"color": Color.RED,
		})
	assert_eq(sys.sync(w), 8, "池上限 8 → 只显示 8 个")
	assert_eq(sys.last_dropped, 2, "超出池的应被统计(而不是静默扩容)")
	assert_eq(sys.pooled_count(), 8, "池大小应保持在 bind 时的大小")
	assert_eq(PopupTextSystem.advance(w, 2.0), 10, "寿命耗尽应全部回收")
	assert_eq(w.count(PopupTextComponent), 0, "回收后实体清空")
	root.free()
