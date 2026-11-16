class_name SpawnerComponent
extends ECSComponent

## ⚠ 示例代码（项目侧，不属于框架 API）: 框架只提供 ECS 核心 + 引擎桥(Timer/MultiMesh/Node 同步)。
## 本模块演示的是用法; 复制到项目时建议改名前缀(如 GameXxx), 避免与项目自身类冲突。

## 生成器（波次/弹幕/刷怪）—— 一个生成器一个实体。
##
## 为什么用 ECS 而不是每帧 `for i in per_wave: create_entity()`:
##   生成走 `instantiate(prefab, n)`（一次跨语言建 n 个, 且直接按模板拷列）,
##   而不是 n 次 create + n 次 add_component。1000 个一批:
##   逐个建约 5.8µs/个(5.8ms) → 批量约 0.05ms 量级。
##
## 用法：
##   var s := SpawnerSystem.add(world, bullet_prefab, 0.25, 50, 600)
##   SpawnerSystem.tick(world, delta)     # 每帧一次

## 要实例化的 prefab 实体 id(见 world.create_prefab)。
## ⚠ 用 -1 表示"未设置": 实体 id **可能为 0**(进程里第一个实体就是 0), 不能用 0 当无效值。
@export var prefab: int = -1
## 每波间隔(秒)
@export var interval: float = 1.0
## 每波生成数量
@export var per_wave: int = 10
## 累计上限(<=0 = 无限)
@export var max_total: int = 0
## 已累计生成(内部状态, 系统维护)
@export var spawned: int = 0
## 计时累积(内部状态, 系统维护)
@export var elapsed: float = 0.0
## 是否启用(停用的生成器仍保留实体, 方便开关)
@export var enabled: bool = true
## 业务分组(波次编号/武器 id...), 开放集合, 生成事件原样带出
@export var tag: int = 0
