@tool
extends RefCounted

## ======= 工具结果封装内核 =======
## 由 MCPDevServer 以 preload 常量 `MCPResult` 引用。**必须带 @tool 且不声明 class_name**。
## 唯一零状态依赖的部分 —— 所有 handler 都调它, 它不调任何人, 故可独立演进、独立单测。
## 分类常量请写 MCPResult.CAT_*(唯一定义处在此)。

## error_category 取值(唯一定义处)。新代码请用下面的**语义化封装**, 不要拼裸字符串 ——
const CAT_VALIDATION := "validation"      # 输入/代码问题: 同参数重试永远失败(改参数后重试有效)
const CAT_TRANSIENT := "transient"        # 暂时性故障(超时/未就绪): 等待后重试可能成功
const CAT_GAME_STOPPED := "game_stopped"  # 游戏进程已结束/崩溃: 必须重启游戏
const CAT_GAME_BREAKED := "game_breaked"  # 游戏被调试器暂停(脚本错误/断点): 进程活着但主循环停着
const CAT_STALE_CODE := "stale_code"      # 代码已改动而本进程跑的是旧版: 需重启对应进程
const CAT_INTERNAL := "internal"          # 服务器内部错误: 不应重试同参数
##
## game_control(action=continue) 解除暂停。合并会让 AI 用"等待"应对一个必须人工介入的状态。


## 统一工具结果封装
static func make(text: String, is_error: bool, extra: Dictionary = {}, content_text: String = "") -> Dictionary:
	var out := {
		"text": text,
		"is_error": is_error,
		"isError": is_error,
		"content": [ {"type": "text", "text": content_text if not content_text.is_empty() else text}],
		# 【协议契约】MCP 2025-06-18 起: 工具一旦在 tools/list 声明 outputSchema(MCPToolMeta 对
		# 所有工具一律声明 {"type":"object"}), 则**每个**结果都必须带符合该 schema 的
		# structuredContent —— 否则合规客户端会把它判成 -32600 InvalidRequest(实测: 报错时正常、
		"structuredContent": {},
	}
	for key in extra:
		out[key] = extra[key]
	return out


static func ok(text: String) -> Dictionary:
	return make(text, false)


## 简写失败封装: 分类固定为 validation, 但**不**把元数据塞进 content[].text。
## 还是重启)必须进 content[], AI 看不到就会盲目重试; 不会改变的(validation 类 message 本身已
static func fail(text: String) -> Dictionary:
	return make(text, true, {
		"error_category": CAT_VALIDATION,
		"is_retryable": false,
		"structuredContent": {
			"message": text,
			"error_category": CAT_VALIDATION,
			"is_retryable": false,
		},
	})


## 结构化结果封装: 数据同时以 structuredContent 与 content[].text(序列化 JSON, 向后兼容)
## 【为什么不再做 JSON 往返】这里曾写成 JSON.stringify -> JSON.parse_string 再放进
## structuredContent, 意图是"只留 JSON 安全的形状"。代价是 Godot 的 JSON 解析把**所有**数字
## 变成 float: node_count=5 变成 5.0, 客户端按 schema 的 "type":"integer" 校验时判为不符合
## (实测 get_scene_tree 的 node_count/width/bytes 全带 .0)。Duplicate 一份即可达到同样目的:
## 结构仍是 Dictionary, 而 int 保持 int。真含不可序列化值的调用方本来就会在 stringify 那一步暴露。
static func ok_json(data: Dictionary) -> Dictionary:
	return make(JSON.stringify(data), false, {"structuredContent": data.duplicate(true)})


## 正文与结构化元信息**分离**的封装(补 ok_json 的缺口)。
## 标量元信息(节点总数、是否被截断)供调用方判断要不要续读; meta 同样 duplicate 而非 JSON 往返
## (理由见 ok_json)。
static func ok_with_meta(text: String, meta: Dictionary) -> Dictionary:
	return make(text, false, {"structuredContent": meta.duplicate(true)})


## 把已落盘的 PNG 附到结果里, 让"画面感知"一步到位。
## 此前截图类工具只回文件路径, 调用方得再走一次读图才看得见像素 —— 而工具名与描述都在承诺
## "回答画面长什么样"。省掉这一跳是本函数唯一的目的。
## 超限时不报错(图已落盘, 路径仍在结果里), 只把省略原因写进 image_omitted: 静默丢弃会让
## 调用方以为"这图就是黑的"。
const MAX_INLINE_IMAGE_BYTES := 1572864

static func attach_image(result: Dictionary, path: String, mime: String = "image/png") -> Dictionary:
	if bool(result.get("is_error", false)) or path.is_empty():
		return result
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		result["image_omitted"] = "读不到图片字节: %s" % path
		return result
	if bytes.size() > MAX_INLINE_IMAGE_BYTES:
		result["image_omitted"] = "图片 %d 字节超过内联上限 %d, 已只回路径(可缩小 max_width 重试)" % [
			bytes.size(), MAX_INLINE_IMAGE_BYTES]
		return result
	var content: Array = result.get("content", [])
	content.append({"type": "image", "data": Marshalls.raw_to_base64(bytes), "mimeType": mime})
	result["content"] = content
	return result


## 工具返回"资源链接"(规范 content 类型 resource_link): 让大段文档走 resources 通道, 而不是
static func resource_link(uri: String, name: String, mime_type: String, text: String, description: String = "") -> Dictionary:
	var link := {"type": "resource_link", "uri": uri, "name": name, "mimeType": mime_type}
	if not description.is_empty():
		link["description"] = description
	var out := make(text, false)
	out["content"] = [{"type": "text", "text": text}, link]
	return out


## 语义化错误封装: retryable 由类别固化, 调用方只负责给出恢复动作。


static func err_validation(text: String, recovery: String) -> Dictionary:
	return err(text, CAT_VALIDATION, false, recovery)


static func err_transient(text: String, recovery: String) -> Dictionary:
	return err(text, CAT_TRANSIENT, true, recovery)


static func err_game_stopped(text: String, recovery: String) -> Dictionary:
	return err(text, CAT_GAME_STOPPED, true, recovery)


## 游戏被调试器暂停。recovery 允许覆盖: "错误缓冲无内容"那条分支说的是"缓冲没读到、需你手动
static func err_game_breaked(text: String, recovery: String = "") -> Dictionary:
	return err(text, CAT_GAME_BREAKED, true,
		recovery if not recovery.is_empty() else "get_logs(process=game,kind=error)查错后game_control(action=continue); 或game_control(action=stop)修复重启")


static func err_stale_code(text: String, recovery: String) -> Dictionary:
	return err(text, CAT_STALE_CODE, true, recovery)


## recovery 可省略(传空串等价): 省略时退回通用的"看日志"指引。需要具体下一步的调用点应显式给出。
static func err_internal(text: String, recovery: String = "") -> Dictionary:
	return err(text, CAT_INTERNAL, false,
		recovery if not recovery.is_empty() else "查看编辑器控制台或调用 get_logs 获取详情。")


## 底层结构化错误封装。category 取值见 CAT_*; retryable 由语义化封装固化, 仅当它需按上下文
## 元数据必须进 content[].text, 不能只平铺在顶层: 协议客户端读的是 content[], 只平铺在顶层的话
static func err(text: String, category: String, retryable: bool, recovery: String) -> Dictionary:
	var data := {
		"message": text,
		"error_category": category,
		"is_retryable": retryable,
		"recovery": recovery,
	}
	return make(text, true, {
		"error_category": category,
		"is_retryable": retryable,
		"recovery": recovery,
		"structuredContent": data,
	}, JSON.stringify(data))


## ======= 协议边界净化 =======
## 为什么必须剥: 这两个字段**不是 MCP 协议字段**(50+ 处内部逻辑读它们), 而 text 与
## 实测 read_file 读 MCPDevServer.gd(33K 正文): 响应 74336 字符, 其中 33353 是纯重复, 占
static func for_protocol(result: Dictionary) -> Dictionary:
	if not result.has("text") and not result.has("is_error"):
		return result
	var out := result.duplicate()
	out.erase("text")
	out.erase("is_error")
	return out
