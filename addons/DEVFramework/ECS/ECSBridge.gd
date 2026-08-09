class_name ECSBridge
extends RefCounted

## 通用 ECS ↔ 任意对象字段同步工具 —— 任何 Node/对象可用, 不依赖 Entity 子类。
## 用于"把 ECS 实体某个字段 同步到 任意对象/节点属性"(双向)。
##
## 用法:
##   ECSBridge.sync_from(link, comp, &"pos", node, &"position")   # ECS → 节点(把实体 pos 写到 node.position)
##   ECSBridge.sync_to(link, comp, &"position", node, &"pos")     # 节点 → ECS(把 node.position 写回实体 pos)
##
## link: ECSLink(实体关联, 如 entity.ecs / Entity2D.ecs); comp: 组件类; field: ECS 字段名;
## obj: 任意对象/节点; obj_prop: 对象属性名。
## 也可在 Entity2D/3D 上直接用便捷方法 sync_from_ecs(field, node_prop) / sync_to_ecs(node_prop, field)。


## 从 ECS 同步字段值到对象属性(ECS → 对象)。
static func sync_from(link, comp, field: StringName, obj, obj_prop: StringName) -> void:
	if link == null or obj == null:
		return
	obj.set(obj_prop, link.get_field(comp, field))


## 从对象属性同步值到 ECS 字段(对象 → ECS)。
static func sync_to(link, comp, field: StringName, obj, obj_prop: StringName) -> void:
	if link == null or obj == null:
		return
	link.set_field(comp, field, obj.get(obj_prop))
