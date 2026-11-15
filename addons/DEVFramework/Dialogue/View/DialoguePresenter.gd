@tool
## 对话/提示的**表现基类** — 框架只定义"要具备哪些能力", 长什么样由项目实现。
##
## 项目做法(任选):
##   1. 继承本类, 覆盖 `present()` / `dismiss()`(自己的 Panel/Label/动画);
##   2. 或在 DialogueTool 里注册一个任意 Control + 实现这几个方法;
##   3. 框架自带的 `BubblePresenter` 只是"默认实现", 不需要就换成自己的。
class_name DialoguePresenter extends Control

## 玩家要求推进(点击/按键) —— 由 presenter 发出, Session 负责真正换行
signal advance_requested
## 一次排版完成(项目可在这里做二次布局)
signal placed
signal shown
signal dismissed

## 定位策略: 决定"锚在目标旁边"还是"贴在屏幕某处"
enum Placement {
	FOLLOW_BELOW,
	FOLLOW_ABOVE,
	SCREEN_BOTTOM,
	SCREEN_TOP,
	SCREEN_LEFT_TOP,
	SCREEN_CENTER,
}

@export var placement := Placement.SCREEN_BOTTOM
## 与锚点的间距
@export var gap := 14.0
## 与屏幕边缘的安全距离
@export var screen_margin := 12.0
## 最大/最小宽度(0 = 不限制)
@export var max_width := 720.0
@export var min_width := 0.0
## 最小高度(装立绘/模型时用)
@export var min_height := 0.0
## 排版后顶部不得高于该 Y(-1 = 不限)
@export var limit_top := -1.0

var _anchor := Rect2()
var _view := Vector2.ZERO


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE


# ------------------------------------------------------------
# 需要项目实现的部分(默认空实现, 子系统不会因此崩)
# ------------------------------------------------------------

## 显示一行(或一条纯提示)。line 可能为 null(纯提示), 用 text 兜底。
func present(_line: DialogueLineDef, _text: String) -> void:
	push_warning("DialoguePresenter.present() 未实现: 请在项目里覆盖")


## 收起
func dismiss() -> void:
	visible = false
	dismissed.emit()


## 排版/内容变化后重排(项目实现)
func refresh() -> void:
	pass


## 挂一个插槽(立绘/模型/图标), 由项目解释
func attach_slot(_slot_name: StringName, _node: Control, _size: Vector2) -> void:
	pass


# ------------------------------------------------------------
# 框架提供: 锚点与视图尺寸
# ------------------------------------------------------------

## 调用方(遮罩/教程)每帧喂"锚在哪"
func set_anchor_rect(rect: Rect2, view_size: Vector2) -> void:
	if rect == _anchor and view_size == _view:
		return
	_anchor = rect
	_view = view_size
	_on_anchor_changed()
	refresh()


func get_anchor_rect() -> Rect2:
	return _anchor


func get_view_size() -> Vector2:
	var view := _view
	if view.x <= 0.0 or view.y <= 0.0:
		view = get_viewport_rect().size
	return view


## 锚点变化钩子(项目可覆盖做跟随动画)
func _on_anchor_changed() -> void:
	pass


## 按 placement 算一个位置(项目可直接用, 也可以完全自己排)
func resolve_position(panel_size: Vector2) -> Vector2:
	var view := get_view_size()
	var margin := screen_margin
	var has_anchor := _anchor.size != Vector2.ZERO
	var pos := Vector2(view.x * 0.5 - panel_size.x * 0.5, view.y - margin - panel_size.y)
	match placement:
		Placement.FOLLOW_BELOW:
			if has_anchor:
				pos = Vector2(_anchor.get_center().x - panel_size.x * 0.5, _anchor.end.y + gap)
				if pos.y + panel_size.y > view.y - margin:
					pos.y = _anchor.position.y - gap - panel_size.y
		Placement.FOLLOW_ABOVE:
			if has_anchor:
				pos = Vector2(_anchor.get_center().x - panel_size.x * 0.5, _anchor.position.y - gap - panel_size.y)
				if pos.y < margin:
					pos.y = _anchor.end.y + gap
		Placement.SCREEN_TOP:
			pos.y = margin
		Placement.SCREEN_LEFT_TOP:
			pos = Vector2(margin, margin)
		Placement.SCREEN_CENTER:
			pos = view * 0.5 - panel_size * 0.5
		_:
			pos.y = view.y - margin - panel_size.y
	pos.x = clampf(pos.x, margin, maxf(margin, view.x - panel_size.x - margin))
	pos.y = clampf(pos.y, margin, maxf(margin, view.y - panel_size.y - margin))
	if limit_top >= 0.0:
		pos.y = maxf(pos.y, limit_top)
	return pos
