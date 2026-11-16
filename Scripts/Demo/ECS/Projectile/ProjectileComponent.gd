class_name ProjectileComponent
extends ECSComponent

## ⚠ 示例代码（项目侧，不属于框架 API）: 框架只提供 ECS 核心 + 引擎桥(Timer/MultiMesh/Node 同步)。
## 本模块演示的是用法; 复制到项目时建议改名前缀(如 GameXxx), 避免与项目自身类冲突。

## 投射物（子弹/碎片）—— 纯数据：位置、速度、剩余寿命。
##
## 为什么用列而不是"每颗子弹一个对象/节点":
##   子弹是**无身份、同构、每帧都动**的对象，正是 ECS 的典型场景。
##   推进走"整列读 → 本地循环 → 整列写回"（每帧 2~3 次跨语言），
##   而不是 N 次跨语言或 N 个 Node3D 的变换通知。
##
## 视觉上用 MultiMeshComponent 渲染（同网格同材质成片实例）；两者可以同实体共存。

@export var pos: Vector3 = Vector3.ZERO
@export var vel: Vector3 = Vector3.ZERO
## 剩余寿命(秒)。<= 0 时由 ProjectileSystem 回收(销毁实体)。
@export var life: float = 0.0
## 业务分组(子弹=0/碎片=1...)，回收事件原样带出；与 TimerComponent.tag 同理是开放集合。
@export var tag: int = 0
