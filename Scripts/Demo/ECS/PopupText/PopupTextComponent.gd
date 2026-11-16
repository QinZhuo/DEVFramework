class_name PopupTextComponent
extends ECSComponent

## ⚠ 示例代码（项目侧，不属于框架 API）: 框架只提供 ECS 核心 + 引擎桥(Timer/MultiMesh/Node 同步)。
## 本模块演示的是用法; 复制到项目时建议改名前缀(如 GameXxx), 避免与项目自身类冲突。

## 飘字(伤害数字/提示) —— 纯数据 + 复用节点池。
##
## 为什么不是"每次弹字都 new Label3D + queue_free":
##   弹字是高频短命对象, 创建/销毁节点才是成本; 池化后每帧只改 4 个属性。
## 为什么不用 MultiMesh:
##   MultiMesh 一份网格只能一种字, 而飘字是任意文本 → 必须走节点(Label3D)。
##   这就是"两种渲染后端显式选择"的典型: 数据在 ECS, 视图用节点, 由本系统池化映射。

@export var pos: Vector3 = Vector3.ZERO
## 剩余寿命(秒)
@export var life: float = 1.0
## 总时长(算 alpha 与上升距离)
@export var ttl: float = 1.0
## 每秒上升距离
@export var rise: float = 2.0
## 显示的文本
@export var text: String = ""
## 颜色(alpha 由 life/ttl 决定, 这里只取 rgb)
@export var color: Color = Color.WHITE
## 业务分组(伤害/治疗/暴击...), 开放集合
@export var tag: int = 0
