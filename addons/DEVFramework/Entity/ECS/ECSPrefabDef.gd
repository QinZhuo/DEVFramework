class_name ECSPrefabDef
extends Resource

## ECSPrefabDef —— ECS 实体预制体配置(策划编辑 .tres)。
##
## 描述"一个实体由哪些组件组成、初始值是什么", 供 ECSWorld.build_prefab 使用。
## 策划改 .tres 不改代码 → 批量生成实体。
##
## 用法:
##   # 创建 .tres 资源, 配置 components:
##   #   [{comp: HealthComponent, fields: {max_hp: 100, hp: 100}},
##   #    {comp: MoveComponent,    fields: {speed: 50.0}}]
##   var def = load("res://Assets/Def/ECS/Soldier.tres")
##   var prefab = world.build_prefab(def)     # 配置 → prefab 模板实体
##   var units = world.instantiate(prefab, 100)  # 批量生成 100 个

## 组件配置列表: 每项 {comp: Script(组件类), fields: {字段名: 初始值}}
@export var components: Array = []

## 便捷: 校验配置是否合法(所有组件类可实例化)
func is_valid() -> bool:
	for cd in components:
		if not cd.has("comp") or cd["comp"] == null:
			return false
	return not components.is_empty()
