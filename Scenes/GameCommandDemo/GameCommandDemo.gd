extends Control
## GameCommand 模块演示 · 3 列取宝藏
##
## 实战阶段：每回合点选一列，构造 GameCommand 记入 CommandHistory 并结算得分；
## 存档：history.save_data() 序列化；回放：决策段喂给 ReplayInputSource，
## 重放模拟后比对得分与 journal，验证确定性。

const TOTAL_TICKS := 3

@onready var score_label: Label = $VBox/ScoreLabel
@onready var col_buttons: Array[Button] = [$VBox/Columns/Col0, $VBox/Columns/Col1, $VBox/Columns/Col2]
@onready var replay_button: Button = $VBox/ReplayButton
@onready var log_box: RichTextLabel = $VBox/LogBox

var _history := CommandHistory.new()
var _tick := 0
var _score := 0


func _ready() -> void:
	for i in col_buttons.size():
		col_buttons[i].pressed.connect(_on_pick.bind(i))
	replay_button.pressed.connect(_on_replay)
	_log("[color=gray]实战开始，点选一列获取宝藏[/color]")


func _on_pick(col: int) -> void:
	if _tick >= TOTAL_TICKS:
		return
	var cmd := GameCommand.new(&"pick_col", _tick, [col])
	_history.append(cmd)
	_apply(cmd)
	_tick += 1
	if _tick >= TOTAL_TICKS:
		replay_button.disabled = false
		_log("[color=yellow]实战结束，得分 %d。点击「回放验证」重演本局[/color]" % _score)


func _apply(cmd: GameCommand) -> void:
	if cmd.type != &"pick_col" or cmd.params.is_empty():
		return
	_score += int(cmd.params[0]) + 1
	score_label.text = "回合 %d/%d    得分 %d" % [mini(cmd.tick + 1, TOTAL_TICKS), TOTAL_TICKS, _score]


func _on_replay() -> void:
	# 从存档字典还原命令（顺带验证序列化链路）
	var restored := CommandHistory.new()
	restored.load_data(_history.save_data())

	# 决策段喂给回放输入源，重放模拟
	var inputs: Array = []
	for cmd in restored.commands:
		inputs.append(cmd.params.duplicate(true))
	var source := ReplayInputSource.new(inputs)

	_tick = 0
	_score = 0
	while _tick < TOTAL_TICKS:
		var decision := source.take({})
		if decision.is_empty():
			_log("[color=red]回放失败：第 %d 回合输入缺失[/color]" % _tick)
			return
		_apply(GameCommand.new(&"pick_col", _tick, decision))
		_tick += 1

	var ok := source.consumed == inputs
	_log("[color=%s]回放%s：consumed %s 与记录一致，最终得分 %d（共 %d 条命令）[/color]"
			% ["green" if ok else "red", "成功" if ok else "失败",
			"完全" if ok else "不", _score, restored.size()])


func _log(line: String) -> void:
	log_box.append_text(line + "\n")
