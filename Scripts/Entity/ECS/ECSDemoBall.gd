class_name ECSDemoBall
extends ECSComponent

## ECS 演示小球组件 —— 随机移动 + 生命值周期增减。
## hp 0..100 驱动大小: 0 时消失, 100 时最大。dir 控制 hp 增减方向。

@export var x: float = 0.0
@export var y: float = 0.0
@export var vx: float = 0.0
@export var vy: float = 0.0
@export var hp: float = 50.0
@export var dir: int = 1      # +1 增 / -1 减
@export var size: float = 5.0
