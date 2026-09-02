@tool
## 教程步骤定义 — 继承 SignalTaskDef(完成条件 = 节点信号), 附加教程表现配置。
##
## 一个步骤 = 一个带表现配置的信号任务: 信号触发即完成(纯 Task 逻辑, 复用 SignalTask, 无需新实体类);
## target/tip/拦截只是"播放教程时展示什么", 由 TutorialGuide 读取。
## 流程用 GroupTaskDef 编排, 步骤 Def 即本类。
class_name TutorialStepDef extends SignalTaskDef

## 智能目标(为空 = 纯提示步骤, 不挖孔仅显示提示文字)。
## 有 target 即自动遮挡目标外输入(遮罩挖孔, 完成靠目标自身交互/信号);
## 无 target 即纯提示不遮挡, 并自动"点任意处继续"。
@export var target: TutorialTargetDef
## 提示框屏幕位置(视口归一化 0..1, 以气泡中心为锚)。仅纯提示(无 target)时生效;
## 有 target 时气泡随挖孔/箭头自动摆放, 本字段被忽略。(-1,-1) = 自动(纯提示居中偏上)。
@export var tip_position := Vector2(-1.0, -1.0)


## 无额外字段: 提示文字复用 TaskDef 统一 desc 翻译(tr(名称_desc), 见 Assets/Translation/task.csv)
## 内容支持 BBCode(如 [color=#ffd140]高亮[/color])
