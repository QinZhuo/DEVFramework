class_name BattleCell
extends ECSComponent

## 战斗细胞组件 —— 吞并战斗玩法。
##
## 属性:
##   pos/vel   位置速度
##   hp/max_hp 血量(决定大小)
##   team      阵营 (0=红, 1=蓝)
##   dmg       攻击力
##   size      显示大小(由 hp 决定, 越大越强)

@export var pos: Vector2 = Vector2.ZERO
@export var vel: Vector2 = Vector2.ZERO
@export var hp: float = 100.0
@export var max_hp: float = 100.0
@export var team: int = 0
@export var dmg: float = 5.0
@export var size: float = 10.0
