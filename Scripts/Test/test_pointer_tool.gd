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


func test_reset_clears_all() -> void:
	var n := Node3D.new()
	PointerTool.enter(n)
	PointerTool.begin_drag(n)
	PointerTool.reset()
	assert_true(PointerTool.over == null, "reset 应清悬停登记")
	assert_false(PointerTool.is_dragging(), "reset 应清拖拽登记")
	assert_true(PointerTool.is_blank(), "清空后指针视为在空白处")
	n.free()
