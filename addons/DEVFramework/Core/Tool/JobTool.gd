class_name JobTool extends RefCounted

## 长任务的通用底层：**启动即返回，超窗给凭据，客户端轮询**。
##
## 为什么需要它
## MCP 是请求-响应模型，客户端单次调用通常 30s 左右超时。把几十秒到几分钟的工作塞进一次
## 同步调用，结果是"超时 + 重试 = 重头再跑一遍"。业界统一做法是异步 job：先拿到 id，
## 再轮询状态。这里把它做成**框架底层工具**，任何耗时接口都能直接用，而不是各自实现一套。
##
## 为什么不走 notifications/progress
## 本服务器是短连接 HTTP(请求结束即断开)，发不出服务端主动通知；官方规范也说明进度通知
## 是 MAY 且**不能当作可靠性信号**。所以主路径是轮询，通知最多作为增强。
##
## 客户端只需一条规则:
##   result 里有 `job_id` 且 `running == true` → 调 job_wait(job_id) 反复问, 直到 running == false。
##
## 典型用法(工具侧):
##   var snap := JobTool.start("run_tests", func(): return await TestRunner.run_all(...))
##   if snap.running: return snap          # 交给客户端轮询
##   return snap                            # 已完成, 直接就是结果

## 单次调用最多等多久(毫秒)。MCP 客户端超时普遍 30s, 留 5s 余量给传输与序列化。
const DEFAULT_WAIT_MS := 25000
## job_wait 允许客户端指定的上限(毫秒): 再长也会被客户端自己掐断, 没意义。
const MAX_WAIT_MS := 60000
## 保留多少个已结束 job(超出淘汰最旧的)
const MAX_KEPT_JOBS := 16

static var _jobs: Dictionary = {}
static var _seq := 0
## 当前正在跑的 job(同一时刻只允许一个: 长任务通常改共享状态, 并发会互相污染)
static var _active := ""


## 启动任务并**立即返回**快照。已有任务在跑时返回它的快照(不重跑、不报错)。
## [param work] 协程/普通 Callable。内部可用 `JobTool.report()` 上报进度、
## `JobTool.is_cancelled()` 检查取消。
static func start(key: String, work: Callable) -> Dictionary:
	if _active != "":
		var running := status(_active)
		running["already_running"] = true
		running["hint"] = "已有任务在跑(%s), 这是它的快照; 用 job_wait 轮询而不是重复启动" % str(running.get("key", ""))
		return running
	_seq += 1
	var id := "job_%d" % _seq
	_jobs[id] = {
		"job_id": id, "key": key, "status": "running",
		"progress": 0, "total": 0, "current": "", "message": "",
		"started_at": Time.get_ticks_msec(), "finished_at": 0,
		"result": {}, "cancel_requested": false,
	}
	_active = id
	_prune()
	_run(id, work)   # 有意不 await: 启动即返回
	return status(id)


## 等任务结束(最多 wait_ms)。结束 → 完整结果; 未结束 → 快照(仍是同一个 job_id)。
static func wait(job_id: String, wait_ms := DEFAULT_WAIT_MS) -> Dictionary:
	var id := job_id if job_id != "" else _active
	if id == "":
		return {"error": "没有可等价的 job(还没启动过任务?)"}
	var deadline := Time.get_ticks_msec() + clampi(wait_ms, 0, MAX_WAIT_MS)
	while true:
		var job: Dictionary = _jobs.get(id, {})
		if job.is_empty():
			return {"error": "未知 job_id: '%s'" % id}
		if str(job["status"]) != "running":
			return result(id)
		if Time.get_ticks_msec() >= deadline:
			return status(id)
		await Engine.get_main_loop().process_frame
	return status(id)


static func status(job_id := "") -> Dictionary:
	var id := job_id if job_id != "" else _pick()
	if id == "":
		return {"error": "没有可用的 job(还没启动过任务?)"}
	var job: Dictionary = _jobs.get(id, {})
	if job.is_empty():
		return {"error": "未知 job_id: '%s'(可用: %s)" % [job_id, _ids_text()]}
	return _snapshot(id, job)


## 取结果。未结束时返回快照 + 提示(不阻塞)。
static func result(job_id := "") -> Dictionary:
	var id := job_id if job_id != "" else _pick()
	if id == "":
		return {"error": "没有可用的 job(还没启动过任务?)"}
	var job: Dictionary = _jobs.get(id, {})
	if job.is_empty():
		return {"error": "未知 job_id: '%s'(可用: %s)" % [job_id, _ids_text()]}
	var snap := _snapshot(id, job)
	if str(job["status"]) == "running":
		snap["hint"] = "仍在运行, 用 job_wait 继续等"
		return snap
	snap.merge(job.get("result", {}), true)
	snap["status"] = str(job["status"])
	return snap


static func cancel(job_id := "") -> Dictionary:
	var id := job_id if job_id != "" else _pick()
	var job: Dictionary = _jobs.get(id, {})
	if job.is_empty():
		return {"error": "未知 job_id: '%s'" % job_id}
	job["cancel_requested"] = true
	return {"job_id": id, "cancel_requested": true,
		"hint": "取消在任务的下一个检查点生效(无法中途掐断正在 await 的协程)"}


## 任务内部上报进度。progress 必须是**单调递增**的量(已完成项数), 与 MCP 规范一致。
static func report(progress: int, total := -1, current := "", message := "") -> void:
	if _active == "":
		return
	var job: Dictionary = _jobs.get(_active, {})
	if job.is_empty():
		return
	job["progress"] = maxi(int(job.get("progress", 0)), progress)
	if total >= 0:
		job["total"] = total
	if current != "":
		job["current"] = current
	if message != "":
		job["message"] = message


## 任务内部检查是否被请求取消(在用例/步骤边界调用)
static func is_cancelled() -> bool:
	if _active == "":
		return false
	return bool((_jobs.get(_active, {}) as Dictionary).get("cancel_requested", false))


## 复位(ResetTool 会调)。**只清已结束的任务**: 正在跑的那个必须保留,
## 否则调用方还拿着它的 job_id 轮询时会拿到"未知 job_id"。
static func clear() -> void:
	var running: Dictionary = _jobs.get(_active, {})
	var keep := ""
	if not running.is_empty() and str(running.get("status", "")) == "running":
		keep = _active
	_jobs.clear()
	if keep != "":
		_jobs[keep] = running
	_active = keep


static func _run(id: String, work: Callable) -> void:
	var out: Variant = await work.call()
	var job: Dictionary = _jobs.get(id, {})
	if job.is_empty():
		return  # 被 clear 掉了
	job["result"] = out if out is Dictionary else {"value": out}
	job["finished_at"] = Time.get_ticks_msec()
	job["current"] = ""
	var failed := false
	if out is Dictionary:
		failed = int((out as Dictionary).get("failed", 0)) > 0 or bool((out as Dictionary).get("aborted", false))
	job["status"] = "failed" if failed else "done"
	if _active == id:
		_active = ""


static func _snapshot(id: String, job: Dictionary) -> Dictionary:
	var started := int(job.get("started_at", 0))
	var finished := int(job.get("finished_at", 0))
	var elapsed := (finished if finished > 0 else Time.get_ticks_msec()) - started
	var running := str(job.get("status", "")) == "running"
	return {
		"job_id": id,
		"key": str(job.get("key", "")),
		"status": str(job.get("status", "")),
		"running": running,
		"progress": int(job.get("progress", 0)),
		"total": int(job.get("total", 0)),
		"current": str(job.get("current", "")),
		"message": str(job.get("message", "")),
		"elapsed_ms": elapsed,
		"cancel_requested": bool(job.get("cancel_requested", false)),
	}


static func _pick() -> String:
	if _active != "":
		return _active
	var best := ""
	var best_seq := -1
	for k in _jobs.keys():
		var n := int(str(k).trim_prefix("job_"))
		if n > best_seq:
			best_seq = n
			best = str(k)
	return best


static func _ids_text() -> String:
	var ids: Array = _jobs.keys()
	ids.sort()
	return ", ".join(ids) if not ids.is_empty() else "(无)"


static func _prune() -> void:
	if _jobs.size() <= MAX_KEPT_JOBS:
		return
	var keys: Array = _jobs.keys()
	keys.sort()
	for k in keys:
		if _jobs.size() <= MAX_KEPT_JOBS:
			break
		if str(k) == _active:
			continue
		if str(_jobs[k].get("status", "")) == "running":
			continue
		_jobs.erase(k)
