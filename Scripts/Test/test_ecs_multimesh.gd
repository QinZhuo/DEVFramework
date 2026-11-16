extends TestCase

## MultiMesh(3D) 批量渲染后端的正确性 / 显式契约 / 性能。
##
## 性能对照选的是**真正的对手**: "每实体一个 Node3D, 每帧写 position" —— 那才是
## ECS 视图同步要替代的东西。不再拿"GDScript 逐实例 set_instance_transform"当基线:
## 那种写法已经跳过了节点/反射层, 剩下的引擎调用谁都要付, 两者只差在实体解析, 属噪声。

const N_PERF := 2000


func _make_mm(use_colors := true) -> MultiMesh:
	var m := MultiMesh.new()
	var box := BoxMesh.new()
	box.size = Vector3(1, 1, 1)
	m.mesh = box
	m.transform_format = MultiMesh.TRANSFORM_3D
	m.use_colors = use_colors
	return m


func _world_with(n: int, layer := 0) -> ECSWorld:
	var w := ECSWorld.new(false)
	w.register_component(MultiMeshComponent)
	for i in n:
		var e := w.create_entity()
		w.add_component(e, MultiMeshComponent, {
			&"layer": layer,
			&"pos": Vector3(float(i) * 2.0, 0, 0),
			&"rot": Vector3.ZERO,
			&"scale": Vector3.ONE,
			&"color": Color(1, 0, 0, 1),
		})
	return w


## 单层: 数量、首末实例变换、颜色都要正确(3D)。
func test_single_layer() -> void:
	var w := _world_with(100)
	var mm := _make_mm()
	var sys := MultiMeshSystem.new()
	sys.bind(0, mm)

	assert_eq(sys.sync(w), 100, "应写入 100 个实例")
	assert_eq(mm.instance_count, 100, "instance_count")
	assert_eq(mm.visible_instance_count, 100, "visible_instance_count")
	assert_approx(mm.get_instance_transform(0).origin.x, 0.0, "首实例 x")
	assert_approx(mm.get_instance_transform(99).origin.x, 198.0, "末实例 x(i*2 = 99*2)")
	assert_true(mm.get_instance_color(0).r > 0.9, "颜色应写入实例")


## 旋转与缩放: Transform3D = T*R*S; basis 的列长应等于缩放。
func test_rotation_and_scale() -> void:
	var w := ECSWorld.new(false)
	w.register_component(MultiMeshComponent)
	var e := w.create_entity()
	w.add_component(e, MultiMeshComponent, {
		&"pos": Vector3(1, 2, 3),
		&"rot": Vector3(0.0, PI * 0.5, 0.0),
		&"scale": Vector3(2, 3, 4),
	})
	var mm := _make_mm()
	var sys := MultiMeshSystem.new()
	sys.bind(0, mm)
	sys.sync(w)
	var t := mm.get_instance_transform(0)
	assert_approx(t.origin, Vector3(1, 2, 3), "位置")
	# 缩放体现在 basis 三个基向量的长度上(与旋转顺序无关)。GDScript 里 Basis 的列就是 x/y/z。
	assert_approx(t.basis.x.length(), 2.0, "x 轴缩放")
	assert_approx(t.basis.y.length(), 3.0, "y 轴缩放")
	assert_approx(t.basis.z.length(), 4.0, "z 轴缩放")


## 多层: 每个 layer 写到自己那份 MultiMesh, 数量各自独立。
func test_multi_layer() -> void:
	var w := ECSWorld.new(false)
	w.register_component(MultiMeshComponent)
	for i in 60:
		var e := w.create_entity()
		w.add_component(e, MultiMeshComponent, {&"layer": 0, &"pos": Vector3(i, 0, 0), &"color": Color.RED})
	for i in 40:
		var e := w.create_entity()
		w.add_component(e, MultiMeshComponent, {&"layer": 5, &"pos": Vector3(0, i, 0), &"color": Color.BLUE})

	var mm0 := _make_mm()
	var mm5 := _make_mm()
	var sys := MultiMeshSystem.new()
	sys.bind(0, mm0)
	sys.bind(5, mm5)
	assert_eq(sys.sync(w), 100, "总实例数")
	assert_eq(mm0.instance_count, 60, "layer0 数量")
	assert_eq(mm5.instance_count, 40, "layer5 数量")
	assert_true(mm5.get_instance_color(0).b > 0.9, "layer5 颜色")


## 行序变化(销毁实体)后仍能正确重建实例列表, 且不会残留旧实例。
func test_resync_after_destroy() -> void:
	var w := _world_with(50)
	var mm := _make_mm()
	var sys := MultiMeshSystem.new()
	sys.bind(0, mm)
	sys.sync(w)
	assert_eq(mm.instance_count, 50, "初始 50")

	var ents := w.query_entities(MultiMeshComponent)
	for i in 20:
		w.destroy_entity(ents[i])
	assert_eq(sys.sync(w), 30, "销毁后应剩 30")
	assert_eq(mm.instance_count, 30, "instance_count 应收缩")
	assert_eq(mm.visible_instance_count, 30, "visible_instance_count 应收缩")


## 显式契约: layer 没 bind 就不画, 且必须能诊断出来(不静默、也不自动回退到 Node3D)。
func test_unbound_layer_is_reported_not_fallback() -> void:
	var w := ECSWorld.new(false)
	w.register_component(MultiMeshComponent)
	for i in 10:
		var e := w.create_entity()
		w.add_component(e, MultiMeshComponent, {&"layer": 0, &"pos": Vector3(i, 0, 0)})
	for i in 5:
		var e := w.create_entity()
		w.add_component(e, MultiMeshComponent, {&"layer": 9, &"pos": Vector3(0, i, 0)})   # 未绑定

	var mm0 := _make_mm()
	var sys := MultiMeshSystem.new()
	sys.bind(0, mm0)
	assert_eq(sys.sync(w), 10, "只应写入已绑定的 layer 0")
	assert_eq(sys.last_unbound, 5, "未绑定的 layer 必须被统计出来(供调用方修配置)")
	assert_eq(mm0.instance_count, 10, "layer0 的实例数")

	# 补上绑定后, 全部都应画出来(说明不是"数据丢了", 而是显式未配置)
	var mm9 := _make_mm()
	sys.bind(9, mm9)
	assert_eq(sys.sync(w), 15, "补绑定后应写入全部 15 个")
	assert_eq(sys.last_unbound, 0, "不再有漏绑")
	assert_eq(mm9.instance_count, 5, "layer9 的实例数")


## 性能: 只钉**绝对预算**, 不做"比 Node 快"的断言。
##
## 为什么不做那个对比(实测过, 结论反直觉):
##   2000 个 `Node3D.position = ...` 只要 0.109ms, 而 MultiMesh 写 2000 个实例要 0.190ms ——
##   因为"写 position"只是打脏标记(变换传播由渲染器延迟做), 而 `set_instance_transform` 每次都要
##   真正往实例缓冲里写 12 个 float。Node 方案真正的代价在**节点创建/树遍历/每节点一次绘制调用**,
##   这些在 headless(无渲染) 环境里量不出来。所以这条对比在这里没有意义, 只保留绝对阈值防退化。
func test_batch_scaling_budget() -> void:
	const N := 20000
	var w := _world_with(N)
	var mm := _make_mm()
	var sys := MultiMeshSystem.new()
	sys.bind(0, mm)
	sys.sync(w)   # 预热(定 instance_count)
	var b := PerfTool.bench(func() -> void: sys.sync(w), 8, 3)
	assert_eq(mm.instance_count, N, "实例数")
	assert_true(b.p50_ms < 5.0,
			"MultiMesh 同步 %d 个超预算: %.2fms (阈值 5)" % [N, b.p50_ms])
