@tool
class_name ModelSlotNode extends ModelNode
## 材质槽 —— 让"这段子图归蓝楣子那个颜色"成为可能
##
## 解决的问题：几何节点里布尔运算只产生**形状**，不携带任何"这是哪根柱子"的信息；
## 要分色就得回头改生成器代码，于是每加一种配色都要复制一份生成器。
## 本节点把"材质分区"提升为图里的一等公民：形状照常透传，
## 只在 [method post] 里把这段子图占据的体素标记为某个调色板索引。
##
## == 为什么这是"不用贴图、纯色分件"的前提 ==
## [MeshExtractor] 的着色走"取最近调色板色"那套路径（见 [SdfVoxel]），
## 而它需要的是**每个体素属于哪个槽位**这条信息。SDF 场里原本没有这条信息，
## 于是只能整体一个颜色。有了槽位写入，柱子是木色、屋顶是瓦色、招牌是漆色
## 全部变成**数据**而不是代码 —— 换配色只是换调色板资源，模型一个字节都不用改。
##
## == overwrite 的取舍 ==
## `overwrite = false`：**只填"未被指定"的体素**。这是默认且推荐的 ——
## 上游的槽位节点（柱身红、柱头黑）不会被本节点冲掉，顺序即优先级从外到内。
## `overwrite = true`：覆盖已有指定。用于"先把整段刷成底色，再局部改"的做法。
##
## == 语义前提 ==
## 由 [method SdfField.assign_slot_solid] 提供：把场中**当前实心**的体素标记为 `slot`，
## [code]overwrite = false[/code] 时只动未被指定的体素（先来先得，便于"主体 → 细节"分层赋值）。
## 默认只扫窄带（[code]band_only = true[/code]）：等值面只可能出现在 |d| <= band 的体素上，
## 窄带外的实心体素永远不会被提取器读到，扫它们纯属白烧 CPU。
## 槽位取值 0~253：留 254/255 给"未指定"与"多材质标记"两个哨兵值。

## 调色板索引（0~253）。越界值在写入前被夹紧 —— 存档里的手滑数字不该让整场变花。
var slot: int = 1

## true = 覆盖已有槽位；false = 只填未被指定的体素（推荐，见文件头）。
var overwrite: bool = false

var graph: ModelGraph = null

func bind_graph(g: ModelGraph) -> void:
	graph = g

#region 契约

func bounds_hint() -> AABB:
	## 透传：槽位不改变几何，只写颜色。只填"未指定体素"更不会越出输入范围。
	return ModelNodeAccess.input_bounds(self, &"in")

func shape(_rng: RandomNumberGenerator) -> Callable:
	## 透传 —— 与 [ModelGroupNode] 同理，这里不做任何几何工作。
	return ModelNodeAccess.input_shape(self, &"in")

func post(field: SdfField) -> void:
	## **直接静态调用**，不做能力探测。
	## 早期版本按"基座也许还没提供槽位写入"写成了 [method Object.has_method] + [method Object.callv]
	## 的动态探测，还额外假设基座会提供一个覆盖版 `assign_slot_solid_force` ——
	## 而 [method SdfField.assign_slot_solid] 早已用**第二参数 overwrite** 表达了覆盖语义，
	## 那个 force 方法在全项目里从未存在过（死分支）。
	## 动态调用的代价是槽位赋值整条路径逃过静态类型检查：参数个数写错、签名改名都只会在
	## 烘焙时静默变成 push_warning，而不是编辑器里报错。基座既然有该方法，直接调即可。
	if field == null or field.is_empty():
		return
	field.assign_slot_solid(_safe_slot(), overwrite)

#endregion

#region 内部

## 槽位夹紧到 0~253：留 254/255 给"未指定"与"多材质"哨兵。
func _safe_slot() -> int:
	return clampi(slot, 0, 253)

#endregion

#region 存档 / 调试

func params() -> Dictionary:
	return {"slot": slot, "overwrite": overwrite}

func set_params(d: Dictionary) -> void:
	slot = int(d.get("slot", slot))
	overwrite = bool(d.get("overwrite", overwrite))

func describe() -> String:
	return "槽位#%d%s" % [slot, "(覆盖)" if overwrite else ""]

#endregion
