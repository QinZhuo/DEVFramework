## 对话子系统入口。三条命令够用：
##
##     DialogueTool.bind(ui_layer)          # 只需一次（遮罩会自动做）
##     DialogueTool.show("点这里继续", rect) # 一条提示
##     DialogueTool.play(script)            # 一段对话
##
## 表现层默认是 `BubblePresenter`；想要自己的样子：
##     DialogueTool.presenter_scene = preload("res://你的气泡.tscn")
##     或 DialogueTool.register(MyPresenter.new())
class_name DialogueTool

## 项目可替换的表现场景（须继承 DialoguePresenter）
static var presenter_scene: PackedScene

static var _presenter: DialoguePresenter
static var _session: DialogueSession


# ------------------------------------------------------------
# 绑定
# ------------------------------------------------------------

## 把表现层挂到某个 UI 父节点（重复调用复用实例）
static func bind(parent: Control, z_index := 0) -> DialoguePresenter:
	if _presenter != null and is_instance_valid(_presenter):
		if parent != null and _presenter.get_parent() != parent:
			_presenter.reparent(parent)
		return _presenter
	if parent == null:
		return null
	if presenter_scene != null:
		_presenter = presenter_scene.instantiate() as DialoguePresenter
	if _presenter == null:
		_presenter = BubblePresenter.new()
	_presenter.name = "DialoguePresenter"
	_presenter.z_as_relative = false
	_presenter.z_index = z_index
	parent.add_child(_presenter)
	return _presenter


## 直接塞一个自己的表现层
static func register(presenter: DialoguePresenter) -> void:
	_presenter = presenter


static func presenter() -> DialoguePresenter:
	return _presenter if is_instance_valid(_presenter) else null


static func is_bound() -> bool:
	return presenter() != null


# ------------------------------------------------------------
# 一条提示
# ------------------------------------------------------------

## 显示一条提示；anchor 省略 = 屏幕底部（或 presenter 自己的摆法）
static func show(text: String, anchor := Rect2(), view_size := Vector2.ZERO) -> void:
	var p := presenter()
	if p == null:
		return
	if _session != null:
		_session.cancel()
		_session = null
	if view_size == Vector2.ZERO:
		view_size = p.get_viewport_rect().size
	p.set_anchor_rect(anchor, view_size)
	p.present(null, text)


## 目标移动时每帧调（只更新锚点，不重设文案）
static func set_anchor(anchor: Rect2, view_size := Vector2.ZERO) -> void:
	var p := presenter()
	if p == null:
		return
	if view_size == Vector2.ZERO:
		view_size = p.get_viewport_rect().size
	p.set_anchor_rect(anchor, view_size)


static func hide() -> void:
	var p := presenter()
	if p:
		p.dismiss()


static func text() -> String:
	var p := presenter()
	return (p as BubblePresenter).get_text() if p is BubblePresenter else ""


# ------------------------------------------------------------
# 一段对话
# ------------------------------------------------------------

static func play(script: DialogueScriptDef, ctx: Dictionary = {}) -> DialogueSession:
	var p := presenter()
	if p == null or script == null or script.is_empty():
		return null
	if _session != null:
		_session.cancel()
	_session = DialogueSession.new(script)
	_session.context = ctx
	_session.line_changed.connect(_on_line_changed)
	_session.finished.connect(_on_finished)
	if not _session.start(ctx):
		_session = null
	return _session


static func _on_line_changed(line: DialogueLineDef, _index: int) -> void:
	var p := presenter()
	if p:
		p.present(line, line.display_text() if line else "")


static func _on_finished() -> void:
	var p := presenter()
	if p:
		p.dismiss()
	_session = null


## 推进：有对话 → 下一行；没有 → 关闭提示
static func next() -> bool:
	if _session != null:
		return _session.next()
	hide()
	return false


static func stop() -> void:
	if _session != null:
		_session.cancel()
		_session = null
	hide()


static func is_playing() -> bool:
	return _session != null and _session.running


static func session() -> DialogueSession:
	return _session


## 一行接入"点击/按键推进"：在项目的 _input 里 `if DialogueTool.handle_input(event): 吞掉`
static func handle_input(event: InputEvent) -> bool:
	var p := presenter()
	if p == null or not p.visible:
		return false
	if event.is_action_pressed(&"ui_accept") or event.is_action_pressed(&"ui_cancel"):
		next()
		return true
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			next()
			return true
	return false
