extends TestCase

## UIPanel / UIPanel3D 共享状态机(UIPanelTool)回归。
##
## 锁定三条契约:
## 1) 生命周期顺序 open → opened → close → closed, 且 close 结束时必须**隐藏**;
## 2) 2D 与 3D 面板行为一致(历史上 2D 版 close 不隐藏、3D 版 popup 不 await, 已分叉);
## 3) await_closed() 的版本判定: 等待期间被重新 open() 时, 旧等待返回 false。

var _panels: Array[Node] = []
var _waiter: Array = []


func cleanup() -> void:
	for p in _panels:
		if is_instance_valid(p):
			UITool.unregister(p)
			p.free()
	_panels.clear()
	_waiter.clear()
	# 兜底清栈(有界, 避免异常情况下死循环)
	for i in 5:
		if UITool.is_empty():
			break
		UITool.close_all()


func _new_2d() -> UIPanel:
	var p := UIPanel.new()
	_panels.append(p)
	return p


func _new_3d() -> UIPanel3D:
	var p := UIPanel3D.new()
	_panels.append(p)
	return p


## 后台协程: 等待面板关闭并记录结果(不 await 调用, 让它与测试主体并发)
func _spawn_waiter(p) -> void:
	_waiter.clear()
	_waiter.append(await p.await_closed())


func test_2d_open_close_flow() -> void:
	var p := _new_2d()
	var seq: Array = []
	p.on_open.connect(func(): seq.append("open"))
	p.on_opened.connect(func(): seq.append("opened"))
	p.on_close.connect(func(): seq.append("close"))
	p.on_closed.connect(func(): seq.append("closed"))

	await p.open()
	assert_true(p.is_open, "open 后 is_open 应为 true")
	assert_true(p.visible, "open 后面板应可见")
	assert_eq(UITool.get_stack_size(), 1, "open 后应入栈")

	await p.close()
	assert_false(p.is_open, "close 后 is_open 应为 false")
	assert_false(p.visible, "close 后应隐藏")
	assert_true(UITool.is_empty(), "close 后应出栈")
	assert_eq(seq, ["open", "opened", "close", "closed"], "信号顺序应符合生命周期")


func test_3d_parity_with_2d() -> void:
	var p := _new_3d()
	# 注意: GDScript lambda 按值捕获, bool 需要容器才能把结果带出来
	var closed: Array = []
	p.on_closed.connect(func(): closed.append(true))

	await p.open()
	assert_true(p.is_open and p.visible, "3D 面板 open 后 is_open/visible 应为 true")
	await p.close()
	assert_false(p.is_open, "3D 面板 close 后 is_open 应为 false")
	assert_false(p.visible, "3D 面板 close 后应隐藏(与 2D 对齐)")
	assert_true(not closed.is_empty(), "3D 面板 close 后应触发 on_closed(此前后 2D/3D 分叉)")


func test_toggle_roundtrip() -> void:
	var p := _new_2d()
	await p.toggle()
	assert_true(p.is_open and p.visible, "toggle 应打开面板")
	await p.toggle()
	assert_false(p.is_open or p.visible, "再次 toggle 应关闭并隐藏面板")


func test_await_closed_stale_version() -> void:
	var p := _new_2d()
	await p.open()
	_spawn_waiter(p)          # 后台开始等待本轮关闭
	await p.open()            # 等待期间被重新打开 → 版本自增
	await p.close()           # 触发 on_closed, 后台等待恢复
	if _waiter.is_empty():
		var ml := Engine.get_main_loop()
		if ml:
			await ml.process_frame
	var got: bool = bool(_waiter[0]) if not _waiter.is_empty() else true
	assert_false(got, "期间被重新 open(), 旧等待应返回 false")
