extends Control
## GameCommand 模块演示 · 3 列取宝藏（tick 轮询模型）
##
## 实战：模拟循环每 0.2s 跑一个 tick 并 poll 输入源；点按钮把决策推入
## UI 输入源队列（事件驱动入队 + 轮询消费，回合制/实时通用）。
## 回放：命令序列还原后喂给 ReplayInputSource，重放模拟并比对 consumed。

const TOTAL_PICKS := 3
const TICK_INTERVAL := 0.2

@onready var score_label: Label = $VBox/ScoreLabel
@onready var col_buttons: Array[Button] = [$VBox/Columns/Col0, $VBox/Columns/Col1, $VBox/Columns/Col2]
@onready var replay_button: Button = $VBox/ReplayButton
@onready var log_box: RichTextLabel = $VBox/LogBox

## 演示用 UI 输入源：按钮点击入队，模拟循环轮询消费
class UiSource extends InputSource:
	var pending: Array = []
	func push(p: Array) -> void:
		pending.append(p)
	func poll(_tick: int, _request: Dictionary = {}) -> Array:
		return pending.pop_front() if not pending.is_empty() else []

var _history := CommandHistory.new()
var _ui := UiSource.new()
var _tick := 0
var _acc := 0.0
var _picks := 0
var _score := 0


func _ready() -> void:
	for i in col_buttons.size():
		col_buttons[i].pressed.connect(_on_pick.bind(i))
	replay_button.pressed.connect(_on_replay)
	_log("[color=gray]实战开始（tick 轮询中），点选一列获取宝藏[/color]")


func _process(delta: float) -> void:
	_acc += delta
	while _acc >= TICK_INTERVAL:
		_acc -= TICK_INTERVAL
		_step()


func _step() -> void:
	var decision := _ui.poll(_tick)
	_tick += 1
	score_label.text = "tick %d    得分 %d" % [_tick, _score]
	if _picks >= TOTAL_PICKS or decision.is_empty():
		return
	var cmd := GameCommand.new(&"pick_col", _tick, decision)
	_history.append(cmd)
	_apply(cmd)
	_picks += 1
	if _picks >= TOTAL_PICKS:
		replay_button.disabled = false
		_log("[color=yellow]实战结束，得分 %d。点击「回放验证」重演本局[/color]" % _score)


func _apply(cmd: GameCommand) -> void:
	if cmd.type != &"pick_col" or cmd.params.is_empty():
		return
	_score += int(cmd.params[0]) + 1
	score_label.text = "tick %d    得分 %d" % [_tick, _score]


func _on_replay() -> void:
	# 从存档字典还原命令（顺带验证序列化链路）
	var restored := CommandHistory.new()
	restored.load_data(_history.save_data())

	# 决策段喂给回放输入源，重放模拟
	var inputs: Array = []
	for cmd in restored.commands:
		inputs.append(cmd.params.duplicate(true))
	var source := ReplayInputSource.new(inputs)

	_score = 0
	for cmd in restored.commands:
		var decision := source.poll(cmd.tick)
		if decision.is_empty():
			_log("[color=red]回放失败：tick %d 输入缺失[/color]" % cmd.tick)
			return
		_apply(GameCommand.new(&"pick_col", cmd.tick, decision))

	var ok := source.consumed == inputs
	_log("[color=%s]回放%s：consumed %s 与记录一致，最终得分 %d（共 %d 条命令）[/color]"
			% ["green" if ok else "red", "成功" if ok else "失败",
			"完全" if ok else "不", _score, restored.size()])


func _on_pick(col: int) -> void:
	if _picks < TOTAL_PICKS:
		_ui.push([col])


func _log(line: String) -> void:
	log_box.append_text(line + "\n")
