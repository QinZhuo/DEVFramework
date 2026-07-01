## 3D UI 面板基类
##
## 与 [Panel2D] 接口完全对齐，提供统一的打开/关闭生命周期。
## [method open] — 先注册到 [UIManager] 进行栈管理与层级互斥，然后执行进入动画。
## [method close] — 先执行离开动画，然后从 [UIManager] 自动注销。
## 继承自 [Node3D]，适用于 3D 空间的 UI 面板。
class_name UIPanel3D extends Node3D

# ============================================================
# 导出属性
# ============================================================

## 进入/离开动画，为空则直接切换显隐
@export var show_tween: TweenAnimation

## UI 层级（[UIManager.Layer] 枚举值，数字越大越靠前）
@export var layer: UIManager.Layer = UIManager.Layer.PANEL

# ============================================================
# 状态
# ============================================================

var is_open: bool = false

# ============================================================
# 信号
# ============================================================

## 打开动画开始
signal on_open()
## 打开动画完成
signal on_opened()
## 关闭动画开始
signal on_close()
## 关闭动画完成
signal on_closed()

# ============================================================
# 公开接口
# ============================================================

## 打开面板
##
## 完整流程：注册到 [UIManager] 栈（处理层级互斥）→ 触发 [signal on_open] → 播放进入动画 → 触发 [signal on_opened]。
func open() -> void:
	# 注册到 UIManager 栈（处理层级互斥）
	UIManager.register(self)
	is_open = true
	on_open.emit()
	if show_tween:
		await show_tween.play().finished
	on_opened.emit()

## 关闭面板
func close() -> void:
	is_open = false
	# 从 UIManager 栈注销
	UIManager.unregister(self)
	on_close.emit()
	if show_tween:
		await show_tween.playback().finished
	on_closed.emit()

## 切换打开/关闭。完整流程见 [method open] / [method close]。
func toggle() -> void:
	if is_open:
		await close()
	else:
		await open()

## 弹窗模式：打开面板并等待关闭（可用于异步等待面板交互结果）。
func popup() -> void:
	open()
	await on_closed
