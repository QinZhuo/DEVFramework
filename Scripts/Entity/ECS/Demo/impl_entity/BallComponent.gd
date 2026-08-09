class_name DemoEntityBall
extends ECSComponent

## Entity 节点写法实现的小球组件 —— 数据进 ECS 列。
## 位置/速度由节点传统写法读写(自动进 ECS 列), hp 周期与 size 由 DemoEntityBallSystem 驱动。
## (同 query 里的 BallComponent, 用前缀 DemoEntity 区分实现)

@export var x: float = 0.0
@export var y: float = 0.0
@export var vx: float = 0.0
@export var vy: float = 0.0
@export var hp: float = 100.0
@export var max_hp: float = 100.0
@export var dir: int = 1      # +1 增 / -1 减
@export var size: float = 0.0
