class_name ECSSystem
extends RefCounted

## ECS 系统基类 —— 用户编写系统逻辑的入口。
##
## 用法:
##   class_name HealSystem extends ECSSystem:
##       func required_components() -> Array[Script]:
##           return [HealthComponent]
##       func _run(ctx: ECSSystemContext, delta: float) -> void:
##           var rows: PackedInt32Array = ctx.rows(HealthComponent)
##           var hp: PackedInt32Array = ctx.column(HealthComponent, &"hp")
##           for r in rows:
##               hp[r] += 5
##           ctx.write(HealthComponent, &"hp", hp)
##
## 性能要点:
##   - 高频循环内不要调用 get_field/set_field(单实体跨语言调用);
##     一律用 column()/write() 批量拉取整列, 本地循环后写回。
##   - rows() 返回的正是列下标, 与 column() 返回的数组一一对应。

## 系统启停开关
var enabled: bool = true

## 本系统需要使用的组件类(用于自动注册与查询)
func required_components() -> Array[Script]:
	return []

## 本系统"只读"的组件类。用于依赖图自动推断。
## 默认 = required_components()(假设全部只读), 可覆写以精确声明。
func read_components() -> Array[Script]:
	return required_components()

## 本系统"会写入"的组件类。用于依赖图自动推断。
## 默认 = 空(假设只读), 写入系统请覆写。
## 例: func write_components() -> Array[Script]: return [HealthComponent]
func write_components() -> Array[Script]:
	return []

## 用户实现: 每帧业务逻辑
func _run(_ctx: ECSSystemContext, _delta: float) -> void:
	pass

## 本系统是否允许与其他系统并行执行(同一帧)。
## 并行前提(必须全部满足, 否则请覆写返回 false):
##   - 不访问场景树/节点/渲染/UI 等主线程独占资源
##   - 不依赖帧内其他系统产生的瞬时状态
##   - read_components()/write_components() 已准确声明全部读写组件
## 框架会按"组件访问集合"自动做冲突检测: 访问同一组件的系统自动串行,
## 互不访问的系统才真正并行 —— 无需在此手动指定谁与谁并行。
## 访问场景树/节点的系统(如 ECSSyncSystem)必须覆写返回 false。
func can_run_parallel() -> bool:
	return true
