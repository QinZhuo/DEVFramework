class_name SyncFieldRule
extends Resource

## ECSSyncSystem 字段同步规则条目 —— 场景/Inspector 可配置的单个同步规则:
## 把 ECS 组件 comp 的 field 字段, 每帧同步到关联节点的 prop 属性。
## 例: comp=DemoQueryBall, field="pos", prop="position" → 同步位置。
## 同步规则在创建 ECSSyncSystem 时用 add_field_rule() 声明(见 World._setup_world)。

@export var comp: Script        # ECS 组件脚本(必须继承 ECSComponent)
@export var field: StringName   # 要同步的 ECS 组件字段名
@export var prop: StringName    # 关联节点的属性名(如 position / visual_size / modulate)
