@tool
## 教程步骤定义 — 继承 SignalTaskDef(完成条件 = 节点信号), 附加教程表现配置。
class_name TutorialStepDef extends SignalTaskDef

## 智能目标(为空 = 纯提示步骤, 不挖孔仅显示提示文字)。
@export var target: TutorialTargetDef

## 有 target 时也允许"点击框内继续"(框选说明类步骤用: 只框住目标让玩家认识它, 不等待交互信号)。
@export var click_to_complete_with_target := false

## 静默步骤: 不显示提示气泡、不遮挡输入, 只等信号推进。
## 用于"流程进行中"这类不需要提示、也不能拦住操作的等待阶段(玩家可以自由操作)。
@export var silent := false

## 是否拦截目标之外的输入(默认拦截)。
## 否则挖孔会把后续必须点的区域一起挡住, 形成点了没反应、无法继续的死锁。
@export var block_input := true


## 提示文字复用 TaskDef 统一 desc 翻译(tr(名称_desc), 见 Assets/Translation/task.csv)
func get_desc(data) -> String:
	return "" if silent else super(data)


## 解析目标节点(相对教程托管 host; 未配置或节点缺失 → null)。
func resolve_target(host: Node) -> Node:
	return target.resolve(host) if target else null


## 是否配置了完成信号(继承自 SignalTaskDef.signals)。
func has_signals() -> bool:
	return not signals.is_empty()


## 该步骤是否"点击任意处即可完成"(纯提示、且无完成信号)。
func click_to_complete(host: Node) -> bool:
	if click_to_complete_with_target:
		return true
	return resolve_target(host) == null and not has_signals()


## 同上, 但接收"是否已有可解析目标"的现成判定 —— 供已 resolve 过目标的调用方使用,
func click_to_complete_for(has_target: bool) -> bool:
	if click_to_complete_with_target:
		return true
	return not has_target and not has_signals()
