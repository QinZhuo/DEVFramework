@tool
## 时间缩放工具 — 基于 ModifierValue（×100）管理 Engine.time_scale
##
## base_value = 基础游戏速度（×100），其他 modifier 以 PERCENT 模式叠加。
## 最终值 = base_value × ∏pctᵢ / 100
##
## ⚠️ 改 `time_scale` 的同时抬高物理 tick 频率，使每 tick 的 game delta 保持不变：
## 只放大 `time_scale` 时，同一段"0.1 秒"跨越的物理 tick 数会随速度变少，
## 动画 / 位移 / 物理命中判定的采样粒度随之改变 ⇒ 同样的输入会跑出不同结果。
##
## 频率只跟随 [method set_rate_scale]（离散档位）：高倍速下每帧要跑多个物理步，
## **运行期反复重设物理频率**会让物理时钟与逻辑时钟错位（实测 3x 结果直接分叉），
## 所以档位内的连续微调（动态提速等）只改 `time_scale`。
class_name TimeTool

## 每帧物理步下限（= Godot 默认值）
const MIN_STEPS_PER_FRAME := 8

static var _mv: ModifierValue = null
static var _paused: bool = false
## 档位倍率（离散切换，参与物理频率放大）
static var _rate_scale := 1.0


static func _ensure() -> void:
	if _mv != null:
		return
	_mv = ModifierValue.new()
	_mv.base_value = 100
	_mv.value_changed.connect(func(_m): _apply(_mv.value / 100.0))
	## 物理时钟不"追赶/平滑"真实时间：默认值会按帧率抖动调整每帧物理步数
	## （Godot 文档：值越高，游戏时钟与真实时钟偏差越大，但能平滑帧率抖动）
	## ⇒ 确定性场景必须关掉，否则同样的时间片在不同帧率下跑出的步数不同。
	if "physics_jitter_fix" in Engine:
		Engine.set("physics_jitter_fix", 0.0)


## 物理 tick 基准：取项目设置（改 project.godot 即生效，不写死常量）
static func base_ticks() -> int:
	return int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60))


## 应用缩放：time_scale 照常；物理频率按**档位**同乘
static func _apply(scale: float) -> void:
	if not is_equal_approx(Engine.time_scale, scale):
		Engine.time_scale = scale
	var ticks := roundi(base_ticks() * maxf(get_base_speed() * _rate_scale, 1.0))
	if Engine.physics_ticks_per_second != ticks:
		Engine.physics_ticks_per_second = ticks
	## 每帧物理步上限：Godot 文档要求"提高物理频率时同步调大"，否则低帧率下会变慢/漂移。
	## 按约 5 步/帧给余量（3x → 90Hz，预算 18 步，覆盖 20 FPS 以下）。
	var steps := maxi(MIN_STEPS_PER_FRAME * 2, ticks / 5)
	if Engine.max_physics_steps_per_frame != steps:
		Engine.max_physics_steps_per_frame = steps


## 档位级加速（进战 / 切倍速时设一次）：只有它参与物理频率放大。
static func set_rate_scale(scale: float) -> void:
	_ensure()
	_rate_scale = maxf(scale, 0.0)
	_apply(_mv.value / 100.0)


# ── 基础速度（用户设置） ──

static func set_base_speed(speed: float) -> void:
	_ensure()
	_mv.base_value = roundi(speed * 100)


static func get_base_speed() -> float:
	return _mv.base_value / 100.0 if _mv else 1.0


## 获取当前计算的最终 time_scale（base × modifiers）
static func get_current_scale() -> float:
	return _mv.value / 100.0 if _mv else 1.0


# ── 修改器管理 ──

## 设置 modifier（key 唯一标识），移除旧的再添加新的；scale=1.0 等价于移除
static func set_modifier(key: String, scale: float) -> void:
	_ensure()
	_mv.remove_modifiers(key)
	var pct := roundi(scale * 100)
	if pct != 100:
		_mv.add_modifier(Modifier.new(key, pct, Modifier.Mode.PERCENT))


## 移除指定 key 的 modifier
static func remove_modifier(key: String) -> void:
	if _mv == null:
		return
	_mv.remove_modifiers(key)


## 清空所有 modifier（保留 base 速度）
static func clear() -> void:
	if _mv == null:
		return
	_mv.clear_modifiers()
	_paused = false


# ── 暂停 ──

static func pause() -> void:
	if _paused:
		return
	set_modifier("pause", 0.0)
	_paused = true


static func resume() -> void:
	if not _paused:
		return
	remove_modifier("pause")
	_paused = false


static func is_paused() -> bool:
	return _paused
