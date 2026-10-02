@tool
class_name ModelBatch extends RefCounted
## 分帧烘焙队列 —— 一次烘一个模型，让界面在整个烘焙过程中保持响应
##
## ============================ 为什么必须有它 ============================
## 实测单个中等精度单体烘焙约 1.3 s，一个 14 单体的场景约 18 s（见 SDF/Readme.md
## 性能小节）。同步跑完会**堵死主线程近 18 秒**：窗口不响应、
## [code]SceneTree.current_scene[/code] 取不到，自动化工具会因此报出一堆
## "add_child 失败" 的**次生**错误 —— 排查时极易误判成生成逻辑有问题。
##
## 分帧后每帧只付约 1 s，主循环得以继续，进度条实时刷新。
## 这是**框架职责**，不是调用方的耐心问题：烘焙能被分帧，是因为
## [method ModelGraph.evaluate] 是纯函数、每次调用独立 —— 没有跨调用的可变状态
## 才能这么切。换成有状态算子就切不开了。
##
## == 用法 ==
## [codeblock]
## var batch := ModelBatch.new()
## batch.add(&"shop_0", shop_graph, 1001, {&"style": style, &"voxel_res": 64})
## batch.add(&"shop_1", shop_graph, 1002, {&"style": style})
##
## func _ready() -> void:
##     var ok := await batch.run_async(get_tree())
##     _spawn_all()
##
## func _process(_d: float) -> void:
##     bar.value = batch.progress()                # 任意时刻可查
## [/codeblock]

## 烘完的产物：key → PropBuild
var builds := {}

var _items: Array = []
var _done := 0

# ================================================================== 组队

## 排入一个待烘模型。key 供事后取回，重复 key 会覆盖。
## [param g] 与 [param opt] 的语义见 [method ModelBaker.bake]。
func add(key: StringName, g: ModelGraph, p_seed: int, opt := {}) -> void:
	if g == null:
		push_warning("[ModelBatch] %s 的图为空，已跳过" % key)
		return
	_items.append({"key": key, "graph": g, "seed": p_seed, "opt": opt})

func clear() -> void:
	_items.clear()
	builds.clear()
	_done = 0

func size() -> int:
	return _items.size()

func pending() -> int:
	return maxi(0, _items.size() - _done)

func progress() -> float:
	return 1.0 if _items.is_empty() else float(_done) / float(_items.size())

## 取出烘好的产物（未烘到则为 null）。
func build_of(key: StringName) -> PropBuild:
	return builds.get(key, null)

# ================================================================== 推进

## 烘下一个。返回 true 表示**全部完成**。
##
## 烘失败的条目会记为 null 并继续推进 —— 一个模型失败不该让整个场景停摆，
## 失败原因由 [method ModelBaker.bake] 自己 push_warning。
func step() -> bool:
	if _done >= _items.size():
		return true
	var it: Dictionary = _items[_done]
	var b: PropBuild = ModelBaker.bake(it["graph"], int(it["seed"]), it["opt"])
	builds[it["key"]] = b
	_done += 1
	return _done >= _items.size()

## 协程版：烘完整批，每烘一个让出一帧。[param on_done] 在烘完后调用。
##
## 这是协程，调用方需要 [code]await[/code]；若只想看进度，
## 就自己循环 [method step] 并 [code]await get_tree().process_frame[/code]。
func run_async(tree: SceneTree, on_done := Callable()) -> void:
	while not step():
		await tree.process_frame
	if on_done.is_valid():
		on_done.call()

## 同步烘完整批。**仅**适合测试与极小批量 —— 会阻塞主线程。
func run_all() -> void:
	while not step():
		pass
