## 对话子系统的统一入口(静态)。
##
## 分工:
##   · DialogueTool   —— 谁来播、播哪一段、推进/停止(与 UI 无关)
##   · DialogueSession—— 运行时游标(只发信号)
##   · DialoguePresenter —— 表现(项目实现; 框架只带一个默认气泡)
##
## 典型用法:
##     DialogueTool.bind(layer_control)              # 指定 presenter 挂在哪
##     DialogueTool.show_text("点这里继续", rect)     # 一条纯提示
##     DialogueTool.play(script, {"actor": player})  # 播一段对话
##     DialogueTool.advance()                        # 玩家推进
class_name DialogueTool

static var _presenter: DialoguePresenter
static var _session: DialogueSession
## 项目可在这里注册自己的 presenter 场景(为空 = 默认气泡)
static var presenter_scene: PackedScene


# ------------------------------------------------------------
# 绑定 / 注册
# ------------------------------------------------------------

## 把 presenter 挂到指定父节点(通常是遮罩所在的 UI 层)。重复调用会复用实例。
static func bind(parent: Control, z_index := 0) -> DialoguePresenter:
	if _presenter != null and is_instance_valid(_presenter):
		if parent != null and _presenter.get_parent() != parent:
			_presenter.reparent(parent)
		return _presenter
	if parent == null:
		return null
	_presenter = null
	if presenter_scene != null:
		_presenter = presenter_scene.instantiate() as DialoguePresenter
	if _presenter == null:
		_presenter = BubblePresenter.new()
	_presenter.name = "DialoguePresenter"
	_presenter.z_as_relative = false
	_presenter.z_index = z_index
	parent.add_child(_presenter)
	return _presenter


## 项目可显式塞一个自己的 presenter(它会接管后续所有对话/提示)
static func register(presenter: DialoguePresenter) -> void:
	_presenter = presenter


static func get_presenter() -> DialoguePresenter:
	return _presenter


static func is_bound() -> bool:
	return _presenter != null and is_instance_valid(_presenter)


# ------------------------------------------------------------
# 纯提示(一条文本, 无会话)
# ------------------------------------------------------------

## 显示一条提示。anchor 为空 = 纯提示(按 presenter.placement 摆)。
static func show_text(text: String, anchor: Rect2 = Rect2(), view_size: Vector2 = Vector2.ZERO) -> void:
	if not is_bound():
		return
	if _session != null:
		_session.cancel()  # 纯提示覆盖正在播放的对话
		_session = null
	if view_size == Vector2.ZERO:
		view_size = _presenter.get_viewport_rect().size
	_presenter.set_anchor_rect(anchor, view_size)
	_presenter.present(null, text)


## 只更新锚点(目标移动时每帧调)
static func set_anchor(anchor: Rect2, view_size: Vector2) -> void:
	if is_bound():
		_presenter.set_anchor_rect(anchor, view_size)


static func hide() -> void:
	if is_bound():
		_presenter.dismiss()


# ------------------------------------------------------------
# 对话段
# ------------------------------------------------------------

## 播放一段对话; ctx 会透传给 presenter(项目可读 player/step 等)
static func play(script: DialogueScriptDef, ctx: Dictionary = {}) -> DialogueSession:
	if not is_bound() or script == null or script.is_empty():
		return null
	if _session != null:
		_session.cancel()
	_session = DialogueSession.new(script)
	_session.context = ctx
	_session.line_changed.connect(_on_line_changed)
	_session.finished.connect(_on_finished)
	_session.start(ctx)
	return _session


static func _on_line_changed(line: DialogueLineDef, _index: int) -> void:
	if is_bound():
		_presenter.present(line, line.get_display_text() if line else "")


static func _on_finished() -> void:
	if is_bound():
		_presenter.dismiss()
	_session = null


## 玩家推进: 有会话→下一行; 无会话→当作"关闭提示"
static func advance() -> bool:
	if _session != null:
		return _session.advance()
	if is_bound():
		_presenter.dismiss()
	return false


static func stop() -> void:
	if _session != null:
		_session.cancel()
		_session = null
	if is_bound():
		_presenter.dismiss()


static func is_playing() -> bool:
	return _session != null and _session.is_running


static func get_session() -> DialogueSession:
	return _session
