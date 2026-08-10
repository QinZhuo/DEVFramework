class_name World
extends Node

## ECS 世界桥接层 —— 场景里放一个 ECSWorld(Def) 即可自动实例化并驱动。
##
## 用法(场景驱动):
##   1. 场景根挂本节点(或继承它)。
##   2. @export ecsworld 指定一个 ECSWorld(Def, 可内联或 .tres)。
##   3. 世界的全部设置(注册哪些系统 / 并行 / 核心选项)都在 ECSWorld Def 的 Inspector 里配置。
##   4. _ready 自动按 ecsworld 配置新建运行时世界, _process 自动 tick。
##   5. 切换实现时 = 实例化/删除对应场景, 无需写初始化代码。
##
## 扩展: 继承本类并覆写 _setup_world(world) 做额外配置(如注册额外系统/组件)。

## 世界定义(Def, 场景/Inspector 配置)。为空则自动 new 一个空世界。
@export var ecsworld: ECSWorld = null
## _ready 时自动初始化世界
@export var auto_init := true
## _process 时自动 tick 世界(关闭则手动调 tick(delta))
@export var auto_tick := true

## 实际运行时世界(由 ecsworld 配置新建, 状态独立)。
var ecs: ECSWorld = null


func _ready() -> void:
	if auto_init:
		init_world()


func _process(delta: float) -> void:
	if auto_tick and ecs != null:
		tick(delta)


## 每帧驱动世界(手动 tick 用; auto_tick 关闭时调用)。
func tick(delta: float) -> void:
	ecs.tick(delta)


## 按 ecsworld(Def) 配置新建运行时世界(不复制 C++ 核心, 注册 Def 里配置的系统)。
## 重复调用幂等。返回实际世界。
func init_world() -> ECSWorld:
	if ecs != null:
		return ecs
	if ecsworld == null:
		ecsworld = ECSWorld.new()
	# 新建运行时世界(独立 _core), 应用 Def 配置
	ecs = ECSWorld.new(ecsworld.use_shared_core)
	ecs.parallel_enabled = ecsworld.parallel_enabled
	ecs.parallel_threads = ecsworld.parallel_threads
	# 注册 Def 配置的系统(每系统复制为独立实例, 状态互不干扰)
	for sys in ecsworld.systems:
		if sys == null:
			continue
		ecs.register_system(sys.duplicate(true))
	_setup_world(ecs)
	return ecs


## 覆写点: 世界初始化后的额外配置(如注册额外的系统/组件/容量)。
func _setup_world(_world: ECSWorld) -> void:
	pass
