class_name DemoImpl
extends RefCounted

## 三种 ECS 小球演示实现的统一基类。
## 每个实现独立脚本、独立文件夹, 通过统一接口接入 ECSDemo 调度器(切换/测耗时):
##   setup(count, seed, parent)   创建数据/节点(含显示)
##   tick(delta)                 每帧驱动逻辑(测耗时)
##   teardown()                  销毁本实现全部节点/世界(切换时调用, 只保留当前实现)
##   impl_name                   表格里显示的实现名

var impl_name := "实现"


func setup(_count: int, _seed: int, _parent: Node) -> void:
	pass


func tick(_delta: float) -> void:
	pass


## 销毁本实现创建的全部节点与世界(切换实现时调用, 减少互相影响)。
func teardown() -> void:
	pass
