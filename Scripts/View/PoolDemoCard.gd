extends PanelContainer

## 池化视图示例：显示数据 + 自己的实例号。
## 重刷后实例号不变 = 池真的复用了节点（而不是又 instantiate 了一批）。

var data: int = 0:
	set(value):
		data = value
		_update()

@onready var _label: Label = $Label


func _ready() -> void:
	_update()

## data 可能在进树前就被写入（create_view 先赋值再挂载），故取不到 label 时直接跳过
func _update() -> void:
	if _label == null:
		return
	_label.text = "%d\n#%d" % [data, get_instance_id() % 100000]


func on_pool_get() -> void:
	modulate = Color.WHITE


func on_pool_return() -> void:
	modulate = Color(0.55, 0.55, 0.55)
