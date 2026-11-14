extends TestCase

## 机位竞争的契约：`priority` 大者生效，同级取**最后激活者**，退出的机位不再参与。
## `VirtualCamera3D.current` 是纯静态重算，不需要 Brain 或帧驱动 —— 正因如此它才该被单测：
## 这条规则一旦被改坏，表现是"切镜头没反应"，而不是抛错。
##
## ⚠️ 机位必须**真的在树里**：`_recompute()` 会把 `not is_inside_tree()` 的机位当陈旧登记清掉。
## 而 `--script` 模式下 `root.add_child()` 不会立刻入树（主循环还没跑），所以要等一帧 ——
## 这也是本用例在两个进程里表现不同的唯一原因，别把它当成"环境相关"糊过去。

var _cams: Array[VirtualCamera3D] = []


func cleanup() -> void:
	for c in _cams:
		if is_instance_valid(c):
			c.set_active(false)
			if c.get_parent() != null:
				c.get_parent().remove_child(c)   # 触发 _exit_tree，退出竞争
			c.free()
	_cams.clear()
	VirtualCamera3D.active_cameras.clear()


func _cam(priority := 0) -> VirtualCamera3D:
	var c := VirtualCamera3D.new()
	c.priority = priority
	(Engine.get_main_loop() as SceneTree).root.add_child(c)
	await (Engine.get_main_loop() as SceneTree).process_frame
	_cams.append(c)
	return c


func test_no_active_camera_means_none() -> void:
	var a: VirtualCamera3D = await _cam()
	assert_true(VirtualCamera3D.current == null, "没有任何机位激活时应为 null")
	a.set_active(false)


func test_higher_priority_wins() -> void:
	var low: VirtualCamera3D = await _cam(0)
	var high: VirtualCamera3D = await _cam(10)
	low.set_active(true)
	high.set_active(true)
	assert_true(VirtualCamera3D.current == high, "高优先级机位应生效")


## 同级时"后激活者"生效 —— 这是 UI 里"临时顶一下镜头"的实现方式。
func test_same_priority_last_activated_wins() -> void:
	var a: VirtualCamera3D = await _cam(5)
	var b: VirtualCamera3D = await _cam(5)
	a.set_active(true)
	b.set_active(true)
	assert_true(VirtualCamera3D.current == b, "同级应取最后激活者")

	a.activate()   # 重新激活 → 挪到队尾
	assert_true(VirtualCamera3D.current == a, "重新激活视为最新，应夺回生效权")


func test_deactivate_falls_back() -> void:
	var a: VirtualCamera3D = await _cam(0)
	var b: VirtualCamera3D = await _cam(10)
	a.set_active(true)
	b.set_active(true)
	b.deactivate()
	assert_true(VirtualCamera3D.current == a, "高优先级机位退出后应回落到次高者")
	assert_false(VirtualCamera3D.active_cameras.has(b), "退出的机位不应留在竞争列表里")


func test_active_changed_signal() -> void:
	var a: VirtualCamera3D = await _cam()
	var seen: Array = []
	a.active_changed.connect(func(v): seen.append(v))
	a.set_active(true)
	a.set_active(false)
	assert_eq(seen, [true, false], "active_changed 应只在真正变化时各发一次")


## 重复 set_active(true) 不应把同一机位塞进竞争列表两次（否则"最后激活者"判定会被污染）。
func test_activation_is_idempotent() -> void:
	var a: VirtualCamera3D = await _cam()
	a.set_active(true)
	a.set_active(true)
	var count := 0
	for c in VirtualCamera3D.active_cameras:
		if c == a:
			count += 1
	assert_eq(count, 1, "同一机位在竞争列表里只应出现一次")
