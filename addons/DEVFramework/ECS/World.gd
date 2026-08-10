class_name World
extends Node

## ECS 世界桥接层 —— 场景里配置好系统, 自动创建 ECSWorld 并注册, 无需手写 world 创建/注册代码。
##
## 用法(场景驱动, 推荐):
##   1. 场景里放一个本节点(可作根), Inspector 配置 systems(要注册的系统 Def 实例)。
##   2. _ready 自动创建 ECSWorld + 注册系统; _process 自动 tick 全部系统。
##   3. 需要生成实体等初始化: 监听 world_ready 信号(ecs 已就绪), 或覆写 _setup_world(world)。
##   4. 切换实现时 = 实例化/删除对应场景。
##
## 扩展: 无需每个实现都继承本类; 需要特殊 tick/初始化时用 Spawner 子节点监听 world_ready,
##       或继承本类覆写 _setup_world / tick。

## 要注册的系统(Def 实例, 场景/Inspector 配置)。每个都会被复制为独立实例再注册。
@export var systems: Array[ECSSystem] = []
## 并行线程数(传给 ECSWorld.parallel_threads, 0=自动按硬件)
@export var parallel_threads := 0
## _ready 时自动初始化世界
@export var auto_init := true
## _process 时自动 tick 世界(关闭则手动调 tick(delta), 如由外部测耗时)
@export var auto_tick := true

## 世界初始化完成信号(ecs 已创建 + 系统已注册)。生成实体等初始化在这里做。
signal world_ready(ecs: ECSWorld)

## 实际运行时世界。
var ecs: ECSWorld = null


func _ready() -> void:
	if auto_init:
		init_world()
		world_ready.emit(ecs)


func _process(delta: float) -> void:
	if auto_tick and ecs != null:
		tick(delta)


## 每帧驱动世界(手动 tick 用; auto_tick 关闭时调用)。
func tick(delta: float) -> void:
	ecs.tick(delta)


## 创建世界并注册配置的系统(每系统复制为独立实例, 状态互不干扰)。重复调用幂等。
func init_world() -> ECSWorld:
	if ecs != null:
		return ecs
	ecs = ECSWorld.new()
	ecs.parallel_threads = parallel_threads
	for sys in systems:
		if sys == null:
			continue
		ecs.register_system(sys.duplicate(true))
	_setup_world(ecs)
	return ecs


## 覆写点: 世界初始化后的额外配置(或直接生成实体)。
func _setup_world(_world: ECSWorld) -> void:
	pass


## 渲染开关: 控制场景内 ECSSyncSystem 的 render_enabled(渲染开/关对比用; 无则忽略)。
func set_render_enabled(on: bool) -> void:
	if ecs == null:
		return
	for s in ecs._systems:
		if s is ECSSyncSystem:
			s.render_enabled = on
