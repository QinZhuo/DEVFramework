@tool
## 教程步骤定义 — 继承 SignalTaskDef(完成条件 = 节点信号), 附加教程表现配置。
##
## 一个步骤 = 一个带表现配置的信号任务: 信号触发即完成(纯 Task 逻辑, 复用 SignalTask, 无需新实体类);
## target/tip/拦截只是"播放教程时展示什么", 由 TutorialGuide 读取。
## 流程用 GroupTaskDef 编排, 步骤 Def 即本类。
class_name TutorialStepDef extends SignalTaskDef

## 智能目标(为空 = 纯提示步骤, 不挖孔仅显示提示文字)
@export var target: TutorialTargetDef
## 阻断目标以外的输入(遮罩挖孔, 暗区拦截鼠标)
@export var block_input := true
## 点击目标区域即完成(目标无可交互/无碰撞体时的兜底; 启用后目标区域由遮罩接管点击)
@export var click_to_complete := false


## 无额外字段: 提示文字复用 TaskDef 统一 desc 翻译(tr(名称_desc), 见 Assets/Translation/task.csv)
## 内容支持 BBCode(如 [color=#ffd140]高亮[/color])