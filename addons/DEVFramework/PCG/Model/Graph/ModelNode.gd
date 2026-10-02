@abstract class_name ModelNode extends RefCounted
## 模型生成节点 —— 节点图的最小单元，对标 Houdini SOP / Blender 几何节点的一个节点
##
## ============================ 设计取舍 ============================
## 本框架的节点**不是**"往共享场里写东西的有状态算子"，而是**纯函数**：
## 每个节点产出一个 `func(p: Vector3) -> float`，即一个 SDF 形状函数。
##
## 之所以这样设计：
## · 组合零成本 —— union 就是 min(a,b)、subtract 就是 max(a,-b)，
##   布尔、加噪、变换、阵列全部退化成函数复合，不需要任何"求值顺序"的约定；
## · 无副作用 —— 节点不知道场多大、不知道有多少兄弟节点，
##   因此**天然可复用、可并行求值、可缓存**；
## · 包围盒可提前算 —— 场必须在填充前分配，而分配需要知道形状多大。
##   纯函数让 [method bounds_hint] 能在不求值的前提下由参数直接算出
##   （节点图的 AABB 沿拓扑传播），这是有状态方案做不到的。
##
## 代价：一条 N 节点的链，每个体素采样点要付 N 次 Callable 调用
## （GDScript 单次调用约 0.2µs）。因此**能放到 [method post] 的算子就别放进
## [method shape]** —— post 在整场填充后跑一次，代价与体素数无关。
## 例：硬边化、抽壳都是 post；而噪声位移必须留在 shape（它要改形状本身）。
##
## ============================ 子类实现清单 ============================
## 必填：[method bounds_hint]、[method shape]
## 选填：[method ports]（默认单输入 in）、[method post]、
##      [method describe]、[method params]
##
## 子类**不允许**知道：自己在世界的哪个坐标、旁边有什么、地势高低。
## 位置 / 旋转 / 贴地 / 避让一律由 [PropLayoutTool] 在外层施加。
## ==================================================================

## 本节点在图中的唯一 id。由 [ModelGraph.add] 赋值。
var id: StringName = &""

# ---------------------------------------------------------------- 形状常量

## 空形状：恒定返回大正数。语义上"处处在外部"，是布尔运算的单位元。
## 未连接的输入端口返回它，于是 `union(空, X) == X`、`subtract(X, 空) == X`，
## 节点图因此**天然容忍悬空端口** —— 少连一根线不会崩，只会得到可预期的形状。
static func null_shape(_p: Vector3) -> float:
	return 1.0e9

# ---------------------------------------------------------------- 子类实现

## 输入端口名（按声明顺序）。默认单个输入 `in`。
## 多输入节点（布尔、混合）在此声明，端口名要与 [method shape] 里取的对应。
func ports() -> Array[StringName]:
	var p: Array[StringName] = [&"in"]
	return p

## 保守包围盒（**局部空间**，米；y 从 0 起算）。
##
## 必须在**不求值**的前提下算出来 —— 场要靠它分配，而场要先分配才能求值。
## 做法：把输入端口的包围盒按本节点的语义变换一下
## （变换节点就变换包围盒；并集/差集取并集；阵列取全部实例的并集；
##   噪声按振幅外扩；抽壳按壁厚外扩）。
##
## 只要返回**偏大**的盒子即可（多出来的体素是空的，代价仅是内存与采样）。
## 返回**偏小**则几何会被场边界截断，表现为缺面 —— 宁可大不可小。
@abstract func bounds_hint() -> AABB

## 生成 SDF 形状函数：`func(p: Vector3) -> float`，p 为局部坐标，返回有符号距离（负 = 实心）。
##
## [param rng] 已按节点 id 稳定派生，**同一图 + 同一种子必得同一形状**。
## 需要随机时一律从它取，不要自己 new 随机源。
## 需要输入形状时用 [method ModelGraph.input_shape]，不要自己去问别的节点。
@abstract func shape(rng: RandomNumberGenerator) -> Callable

## 场填充完成后的整场后处理（可选，默认空）。
##
## 放这里的原因：post 对整场只跑一遍，代价与体素数无关；
## 而放进 shape 会让每个采样点多付一次调用。
## 硬边化（[method SdfTool.harden]）、抽壳（[method SdfTool.shell]）都属于此类。
##
## 实现注意：改写了 field 的 data 后窄带缓存会失效，
## [method ModelGraph.fill] 会在**所有** post 跑完后统一重算一次，你不必自己调。
func post(_field: SdfField) -> void:
	pass

# ---------------------------------------------------------------- 通用接口

## 参数快照（存档 / UI 展示用）。默认空；子类按需覆写。
func params() -> Dictionary:
	return {}

## 从参数快照恢复。默认空实现（确定性节点无需恢复）。
func set_params(_d: Dictionary) -> void:
	pass

## 一行中文简述（编辑器列表 / 调试日志）。
func describe() -> String:
	return String(id)

## 新建同类型空节点。用于图的反序列化。
## 不用抽象方法，是为了不让每个子类都写一遍样板。
func make_instance() -> ModelNode:
	return (get_script() as GDScript).new() as ModelNode
