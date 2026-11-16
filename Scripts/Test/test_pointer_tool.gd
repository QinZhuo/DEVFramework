extends TestCase

## PointerTool 的契约：悬停/拖拽登记是**全局单值**，必须能被清理。
## 它强引用 Node3D，切场景后不清就是悬空引用 —— 表现是"点什么都没反应"。


func cleanup() -> void:
	PointerTool.reset()


func test_enter_exit() -> void:
	var n := Node3D.new()
	PointerTool.enter(n)
	assert_true(PointerTool.over == n, "enter 应登记当前对象")
	PointerTool.exit(n)
	assert_true(PointerTool.over == null, "exit 应清掉登记")
	n.free()


## 只有"就是当前对象"才清：A、B 依次进入后，A 离开不能把 B 的登记抹掉。
func test_exit_only_clears_self() -> void:
	var a := Node3D.new()
	var b := Node3D.new()
	PointerTool.enter(a)
	PointerTool.enter(b)
	PointerTool.exit(a)
	assert_true(PointerTool.over == b, "非当前对象的 exit 不应影响登记")
	a.free()
	b.free()


func test_drag_begin_end() -> void:
	var n := Node3D.new()
	PointerTool.begin_drag(n)
	assert_true(PointerTool.is_dragging(), "begin_drag 后应处于拖拽中")
	PointerTool.end_drag()
	assert_false(PointerTool.is_dragging(), "end_drag 后应结束")
	n.free()


## 回归: 拖拽登记不能因为"读不到 OS 按键状态"被自动清掉。
## 曾经在 is_dragging() 里按 Input.is_mouse_button_pressed 自愈, 真机拖拽中途登记被清 ⇒
## DragView3D 立刻认为没在拖(卡片不跟手、drag_ended 不发), 教程的换位判定永远拿不到结果。
func test_drag_survives_without_os_button_state() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var n := Node3D.new()
	tree.root.add_child(n)
	await tree.process_frame
	PointerTool.begin_drag(n)
	for i in 3:
		await tree.process_frame
	assert_true(PointerTool.is_dragging(), "没有 OS 按键状态时也不能清掉拖拽登记")
	PointerTool.end_drag()
	assert_false(PointerTool.is_dragging(), "显式 end_drag 才结束")
	n.queue_free()


func test_reset_clears_all() -> void:
	var n := Node3D.new()
	PointerTool.enter(n)
	PointerTool.begin_drag(n)
	PointerTool.reset()
	assert_true(PointerTool.over == null, "reset 应清悬停登记")
	assert_false(PointerTool.is_dragging(), "reset 应清拖拽登记")
	assert_true(PointerTool.is_blank(), "清空后指针视为在空白处")
	n.free()
