@tool
extends RefCounted

## ======= 工具入参校验(落地 MCP 规范的 MUST validate all tool inputs) =======

## 需要展开成普通 Array 而非原样接受的类型。
const _PACKED := [
	TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY,
	TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY,
]

## 拼写纠错的最大编辑距离。超过它就不再猜 —— 猜错比不猜更害人:
## "最接近 xxx" 若指向语义完全不同的参数, 调用方会照着改。
const _NEAREST_MAX_DISTANCE := 3


## 校验一次 tools/call 的 arguments。返回问题描述数组(空 = 通过)。
static func check(schema: Dictionary, args: Dictionary) -> Array[String]:
	var out: Array[String] = []
	_walk(schema, args, "", out)
	return out


static func _walk(schema: Dictionary, args: Dictionary, prefix: String, out: Array[String]) -> void:
	for key in VariantTool.as_string_array(schema.get("required", [])):
		var at := prefix + key
		if not args.has(key) or VariantTool.is_blank(args[key]):
			out.append('"%s" 是必填参数, 但未提供或为空。' % at)
	var props = schema.get("properties", {})
	if not props is Dictionary:
		return
	# 未知参数必须报错, 不能交给 handler 静默忽略。实测过的两个后果:
	#   get_scene_tree(max_dept=2)  →  用了默认深度 8, 把整棵树回给你, 且 isError=false;
	#   read_file(prober=true)      →  probe 没生效, 走进读文件分支后报"这是目录, 不是文件"。
	# 两种情况下调用方看到的都是"工具坏了", 而真正的原因是参数名拼错。
	_check_unknown(props, args, prefix, out)
	for key in props:
		# 省略的键交给 handler 用默认值处理 —— 在这一层报"缺失"会把所有可选参数变成必填。
		if not args.has(key):
			continue
		var v: Variant = args[key]
		var prop = props[key]
		if not prop is Dictionary:
			continue
		var at := prefix + str(key)
		var tname := str(prop.get("type", ""))
		if not _type_ok(v, tname):
			out.append('"%s" 期望 %s, 实际收到 %s。请直接传符合类型的 JSON 值: 数字不要加引号, 布尔不要写成字符串("true" 不是布尔)。' % [at, tname, _describe(v)])
			continue
		var legal: Variant = prop.get("enum", null)
		if legal is Array and not legal.has(v):
			out.append('"%s" 的值 %s 不在合法取值内。合法值: %s。' % [at, _describe(v), " / ".join(PackedStringArray(legal))])
			continue
		# 只递归显式声明了 properties 的嵌套对象。其余 object 参数(set_node_property 的 value 之类)
		# 没有字段表, 递归进去只会把合法键报成未知。
		if tname == "object" and prop.get("properties", null) is Dictionary:
			_walk(prop, v, at + ".", out)
		elif tname == "array" and prop.get("items", null) is Dictionary:
			# 数组元素声明了 properties 时才逐个查(apply_scene_edits.ops 就是这种形状)。
			# 少了这条, op 内部拼错的字段会被静默忽略, 表现为"某条 op 没生效"而不是报错。
			var item: Dictionary = prop["items"]
			if not item.get("properties", null) is Dictionary:
				continue
			var arr: Array = v if v is Array else Array(v)
			for i in arr.size():
				if arr[i] is Dictionary:
					_walk(item, arr[i], "%s[%d]." % [at, i], out)


## 报出 schema 未声明的参数(拼错的键几乎都落在这里), 能确定时附带最接近的合法参数名。
static func _check_unknown(props: Dictionary, args: Dictionary, prefix: String, out: Array[String]) -> void:
	var known: Array = props.keys()
	for key in args:
		var k := str(key)
		if props.has(key) or props.has(k):
			continue
		# 路由参数: 就地执行前 MCPRouter 已把它摘掉, 但转发与自检路径里可能残留, 不该报成拼写错。
		if k == "instance" and prefix.is_empty():
			continue
		var near := _nearest(k, known)
		var hint := ("(最接近: %s)" % near) if not near.is_empty() else ""
		var names: Array = []
		for known_key in known:
			names.append(str(known_key))
		out.append('"%s%s" 不是本工具的合法参数%s。可用参数: %s。' % [prefix, k, hint, " / ".join(PackedStringArray(names))])


## 找最接近的已知参数名。编辑距离超过阈值的返回空串: 宁可只说"没有这个参数",
## 也不要指向一个语义不相干的参数 —— 那会让调用方照着错的提示改。
static func _nearest(name: String, known: Array) -> String:
	var best := ""
	var best_d := _NEAREST_MAX_DISTANCE
	for k in known:
		var d := _distance(name.to_lower(), str(k).to_lower())
		if d < best_d:
			best_d = d
			best = str(k)
	return best


## Levenshtein 距离。只服务拼写提示, 参数名都在十几个字符内, 直接 O(n*m) 即可。
static func _distance(a: String, b: String) -> int:
	var la := a.length()
	var lb := b.length()
	if la == 0:
		return lb
	if lb == 0:
		return la
	var prev: Array[int] = []
	for j in lb + 1:
		prev.append(j)
	for i in range(1, la + 1):
		var cur: Array[int] = [i]
		for j in range(1, lb + 1):
			var cost := 0 if a[i - 1] == b[j - 1] else 1
			cur.append(mini(mini(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost))
		prev = cur
	return prev[lb]


## 值能否被该 schema 类型承载。未声明 type 的一律放行: 由"没写"推导出凭空冒出来的限制,
## 会把合法的调用拦在门外。
static func _type_ok(v: Variant, tname: String) -> bool:
	match tname:
		"integer", "number":
			# 两者都收 int 与 float: JSON 本身区分不了 3 与 3.0, 解析器给出哪一种取决于客户端
			return v is int or v is float
		"boolean":
			return v is bool
		"string":
			# 数字字符串放行(项目内表单手填的常态)。反过来必须报错: 数组/字典传给 string 参数时
			# 应当显式失败, 否则会被静默转成 "[]" 这种看着像值的字符串。
			return v is String or VariantTool.is_number(v)
		"array":
			return v is Array or typeof(v) in _PACKED
		"object":
			return v is Dictionary
	return true


## 报给调用方看的值描述。容器只报类型不展开: 展开只会刷屏, 且对"改掉这个参数"毫无帮助。
static func _describe(v: Variant) -> String:
	var t := type_string(typeof(v))
	if v is Array or v is Dictionary:
		return t
	var s := str(v)
	return t if s.is_empty() else '%s("%s")' % [t, s]
