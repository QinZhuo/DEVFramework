@tool
## 教程步骤定义 — 继承 SignalTaskDef(完成条件 = 节点信号), 附加教程表现配置。
##
## 一个步骤 = 一个带表现配置的信号任务: 信号触发即完成(纯 Task 逻辑, 复用 SignalTask, 无需新实体类);
## target/tip/拦截只是"播放教程时展示什么", 由 TutorialManager 读取。
## 流程用 GroupTaskDef 编排, 步骤 Def 即本类。
class_name TutorialStepDef extends SignalTaskDef

## 智能目标(为空 = 纯提示步骤, 不挖孔仅显示提示文字)。
## 有 target 即自动遮挡目标外输入(遮罩挖孔, 完成靠目标自身交互/信号);
## 无 target 即纯提示不遮挡, 并自动"点任意处继续"。
@export var target: TutorialTargetDef

## 有 target 时也允许"点击框内继续"(框选说明类步骤用: 只框住目标让玩家认识它, 不等待交互信号)。
## 未开启时保持默认语义: 有 target 的步骤只能靠目标交互/信号完成。
@export var click_to_complete_with_target := false

## 静默步骤: 不显示提示气泡、不遮挡输入, 只等信号推进。
## 用于"流程进行中"这类不需要提示、也不能拦住操作的等待阶段(玩家可以自由操作)。
@export var silent := false

## 是否拦截目标之外的输入(默认拦截)。
## 关闭后: 仍框住目标做视觉引导, 但玩家可以自由点击任意位置。
## 用于"目标只是多段操作的第一步"的步骤(点目标 → 弹出面板 → 还需点面板内按钮),
## 否则挖孔会把后续必须点的区域一起挡住, 形成点了没反应、无法继续的死锁。
@export var block_input := true


## 提示文字复用 TaskDef 统一 desc 翻译(tr(名称_desc), 见 Assets/Translation/task.csv)
## 内容支持 BBCode(如 [color=#ffd140]高亮[/color]); 静默步骤不给文案(空文本 = 隐藏气泡)
func get_desc(data) -> String:
	return "" if silent else super(data)


## 解析目标节点(相对教程托管 host; 未配置或节点缺失 → null)。
## 完成语义归口: 表现层据此判定"是否有 target"(有则挖孔拦阻、靠目标交互/信号完成)。
func resolve_target(host: Node) -> Node:
	return target.resolve(host) if target else null


## 是否配置了完成信号(继承自 SignalTaskDef.signals)。
## 完成语义归口: 表现层据此判定"无 target 时是否靠信号推进"。
func has_signals() -> bool:
	return not signals.is_empty()


## 该步骤是否"点击任意处即可完成"(纯提示、且无完成信号)。
## 完成语义归口: "有 target 靠交互/信号、无 target 有信号等信号、无 target 无信号点击继续"
## 三态由此判定, 教程驱动(点击完成)与表现层(是否画全屏暗区)共用, 不各自推导。
func click_to_complete(host: Node) -> bool:
	if click_to_complete_with_target:
		return true
	return resolve_target(host) == null and not has_signals()


## 同上, 但接收"是否已有可解析目标"的现成判定 —— 供已 resolve 过目标的调用方使用,
## 避免重复解析(表现层 show_step 已解析 target, 无需再走一次 resolve)。
func click_to_complete_for(has_target: bool) -> bool:
	if click_to_complete_with_target:
		return true
	return not has_target and not has_signals()
