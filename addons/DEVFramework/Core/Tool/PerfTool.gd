class_name PerfTool extends RefCounted
## 性能采样底座 —— 计时 / 重复采样统计 / 帧率采样 / 滚动窗口 / 历史耗时基线。
## 一切"测多快"的地方都走这里, 不要再各处手写 `Time.get_ticks_usec` 差值 + 自己求平均。
## Reset: 进程级（历史基线跨场景/跨轮次复用, 不随会话复位；需要重设基线用 clear_history）
##
## 为什么看分位而不是平均: 卡顿来自长尾, 算术平均会把偶发的 200ms 尖峰稀释掉。
## 为什么要 warmup: 首次 load / 着色器编译 / 缓存填充比稳态高一个量级, 不预热测的是冷启动。

## 历史基线的落盘位置(跨进程复用: 编辑器跑一轮、游戏跑一轮, 基线是同一份)
const HISTORY_PATH := "user://.dev_framework/perf_history.json"
const HISTORY_VERSION := 1
## 基线条目上限(超出淘汰最久未更新的), 避免长项目无限堆积
const HISTORY_MAX := 300
## EMA 平滑系数: 单次离群(机器抖动/首次编译)不该主导下一次预估
const EMA_ALPHA := 0.3
## 卡顿阈值(毫秒): 约 2 帧 @60fps, 超过即记一次 stutter
const STUTTER_MS := 33.4

static var _history: Dictionary = {}
static var _history_loaded := false
static var _history_dirty := false
static var _monitors_on := false


# ============================================================
# 计时
# ============================================================

static func now_us() -> int:
	return Time.get_ticks_usec()


static func to_ms(usec: int) -> float:
	return float(usec) / 1000.0


## 单次耗时(毫秒)。
static func measure(action: Callable) -> float:
	var t0 := now_us()
	action.call()
	return to_ms(now_us() - t0)


## 重复采样: 先 warmup 次丢弃, 再 iters 次统计。返回 {count, avg_ms, p50_ms, p95_ms, p99_ms, min_ms, max_ms, total_ms}。
static func bench(action: Callable, iters := 30, warmup := 5) -> Dictionary:
	for i in maxi(warmup, 0):
		action.call()
	var win := Rolling.new(maxi(iters, 1))
	var t0 := now_us()
	for i in maxi(iters, 1):
		var s := now_us()
		action.call()
		win.push(to_ms(now_us() - s))
	var r := win.stats()
	r["total_ms"] = to_ms(now_us() - t0)
	return r


## 对一组耗时值求统计(入参 Array / PackedFloat64Array / PackedFloat32Array)。
static func stats(values: Variant) -> Dictionary:
	var arr: Array = []
	if values is Array:
		arr = values
	elif values is PackedFloat64Array or values is PackedFloat32Array or values is PackedInt32Array:
		arr = Array(values)
	arr.sort()
	var n := arr.size()
	if n == 0:
		return {"count": 0, "avg_ms": 0.0, "p50_ms": 0.0, "p95_ms": 0.0, "p99_ms": 0.0, "min_ms": 0.0, "max_ms": 0.0}
	var sum := 0.0
	for v in arr:
		sum += float(v)
	return {
		"count": n,
		"avg_ms": sum / float(n),
		"p50_ms": _pick(arr, 0.50),
		"p95_ms": _pick(arr, 0.95),
		"p99_ms": _pick(arr, 0.99),
		"min_ms": float(arr[0]),
		"max_ms": float(arr[n - 1]),
	}


## 最近邻分位: 已排序数组里取第 ceil(p*n) 个。
static func _pick(sorted: Array, p: float) -> float:
	var i := clampi(int(ceil(p * float(sorted.size()))) - 1, 0, sorted.size() - 1)
	return float(sorted[i])


# ============================================================
# 帧率 / 引擎指标
# ============================================================

## 当前进程的即时指标(不做采样, 零等待)。
static func snapshot() -> Dictionary:
	var fps := Engine.get_frames_per_second()
	return {
		"fps": fps,
		"frame_ms": 0.0 if fps <= 0 else 1000.0 / float(fps),
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"mem_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
	}


## 采一段真实帧时间(会 await 若干帧, 只能在主循环里调)。
## 返回 stats 的全部字段 + {frames, fps, fps_p50, fps_p95, stutter, draw_calls, mem_mb}。
static func sample_frames(frames := 120, warmup := 30) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return {"error": "没有主循环(SceneTree), 无法采样帧时间"}
	var win := Rolling.new(maxi(frames, 1))
	for i in maxi(warmup, 0):
		await tree.process_frame
	var prev := now_us()
	for i in maxi(frames, 1):
		await tree.process_frame
		var now := now_us()
		win.push(to_ms(now - prev))
		prev = now
	var r := win.stats()
	r["frames"] = win.size()
	# 由 p50/p95 反推的等效帧率: 比瞬时 fps 更能代表稳定性
	r["fps_p50"] = _ms_to_fps(float(r["p50_ms"]))
	r["fps_p95"] = _ms_to_fps(float(r["p95_ms"]))
	r["stutter"] = win.count_over(STUTTER_MS)
	r.merge(snapshot(), true)
	return r


## 把帧时间/绘制调用挂进编辑器 Remote 的 Monitors 面板(游戏进程里调一次即可, 幂等)。
## 只在游戏进程生效: 编辑器自己的帧率没有参考价值。
static func register_monitors() -> void:
	if _monitors_on or Engine.is_editor_hint():
		return
	_monitors_on = true
	Performance.add_custom_monitor("Perf/FrameMs", _mon_frame_ms)
	Performance.add_custom_monitor("Perf/DrawCalls", _mon_draw_calls)


static func _mon_frame_ms() -> float:
	return 1000.0 / maxf(float(Engine.get_frames_per_second()), 1.0)


static func _mon_draw_calls() -> float:
	return Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)


static func _ms_to_fps(ms: float) -> float:
	return 0.0 if ms <= 0.0 else 1000.0 / ms


# ============================================================
# 滚动窗口: 定长环形缓冲, 写入 O(1)(不要再用 Array + pop_front, 那是 O(n))
# ============================================================

class Rolling:
	var _cap: int
	var _items := PackedFloat64Array()
	var _pos := 0

	func _init(capacity: int) -> void:
		_cap = maxi(capacity, 1)

	func push(v: float) -> void:
		if _items.size() < _cap:
			_items.append(v)
			return
		_items[_pos] = v
		_pos = (_pos + 1) % _cap

	func size() -> int:
		return _items.size()

	func is_empty() -> bool:
		return _items.is_empty()

	func clear() -> void:
		_items.clear()
		_pos = 0

	func avg() -> float:
		if _items.is_empty():
			return 0.0
		var s := 0.0
		for v in _items:
			s += v
		return s / float(_items.size())

	## 峰值(最大值)
	func peak() -> float:
		var m := 0.0
		for v in _items:
			m = maxf(m, v)
		return m

	func percentile(p: float) -> float:
		var arr := Array(_items)
		arr.sort()
		return 0.0 if arr.is_empty() else PerfTool._pick(arr, p)

	func count_over(limit: float) -> int:
		var n := 0
		for v in _items:
			if v > limit:
				n += 1
		return n

	func stats() -> Dictionary:
		return PerfTool.stats(_items)


# ============================================================
# 历史耗时基线(ETA 预估的数据源)
# ============================================================

## 某条基线的当前值: {ms(EMA), last_ms, n, updated}。没有记录返回空字典。
static func history(key: String) -> Dictionary:
	_ensure_history()
	return (_history.get(key, {}) as Dictionary).duplicate()


static func history_all() -> Dictionary:
	_ensure_history()
	return _history.duplicate(true)


## 记录一次实测耗时(毫秒)。只更新内存, 落盘由 flush_history() 统一做(逐条 open/close 太贵)。
## 0 是合法值(亚毫秒的逻辑), 不要按"无效数据"丢掉 —— 丢掉后那条基线永远建不起来。
static func record(key: String, ms: float) -> void:
	if key.is_empty() or ms < 0.0:
		return
	_ensure_history()
	var e: Dictionary = _history.get(key, {})
	var n := int(e.get("n", 0))
	e["ms"] = ms if n == 0 else lerpf(float(e.get("ms", ms)), ms, EMA_ALPHA)
	e["last_ms"] = ms
	e["n"] = n + 1
	e["updated"] = int(Time.get_unix_time_from_system())
	_history[key] = e
	_history_dirty = true


## 按基线给出建议预算(毫秒, 向上取整到秒)。没有基线返回 0。
static func suggest_ms(key: String, factor := 1.5, floor_ms := 1000) -> int:
	var e := history(key)
	if e.is_empty():
		return 0
	return maxi(floor_ms, int(ceil(float(e.get("ms", 0.0)) * factor / 1000.0)) * 1000)


static func forget(key: String) -> void:
	_ensure_history()
	if _history.erase(key):
		_history_dirty = true


static func clear_history() -> void:
	_history.clear()
	_history_loaded = true
	_history_dirty = false
	FileTool.write_text(HISTORY_PATH, JSON.stringify({"v": HISTORY_VERSION, "items": {}}, "\t"))


static func flush_history() -> void:
	if not _history_dirty:
		return
	_history_dirty = false
	_prune_history()
	FileTool.write_text(HISTORY_PATH, JSON.stringify({"v": HISTORY_VERSION, "items": _history}, "\t"))


static func _ensure_history() -> void:
	if _history_loaded:
		return
	_history_loaded = true
	var text := FileTool.read_text(HISTORY_PATH)
	if text.is_empty():
		return
	var data: Variant = JSON.parse_string(text)
	if data is Dictionary and data.get("items") is Dictionary:
		_history = data["items"]


## 超上限时按 updated 升序淘汰最旧的条目
static func _prune_history() -> void:
	if _history.size() <= HISTORY_MAX:
		return
	var keys: Array = _history.keys()
	keys.sort_custom(func(a, b) -> bool:
		return int(_history[a].get("updated", 0)) < int(_history[b].get("updated", 0)))
	for i in _history.size() - HISTORY_MAX:
		_history.erase(keys[i])


# ============================================================
# 格式化
# ============================================================

## 统一耗时文案: 900 → "900ms"; 12500 → "12.5s"; 125000 → "2m05s"。
static func fmt_ms(ms: float) -> String:
	var v := int(round(ms))
	if v < 1000:
		return "%dms" % v
	if v < 60000:
		return "%.1fs" % (float(v) / 1000.0)
	return "%dm%02ds" % [v / 60000, (v % 60000) / 1000]
