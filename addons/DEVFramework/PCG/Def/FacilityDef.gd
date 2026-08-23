@tool
class_name FacilityDef extends Resource
## 城镇功能设施定义 — 城镇 S5 阶段用（原 PoiDef，POI 为行业黑话故更名）
##
## 一个 FacilityDef 描述一类必有功能建筑（酒馆/教堂/铁匠铺…）：
## count 为该类建筑的数量期望（整数部分必出，小数部分按概率 +1）；
## templates 为专属户型库（含专属家具槽位字符），留空则回退通用 houses 库。

@export var facility_name := "酒馆"
## 数量期望：整数部分必出，小数部分按概率额外 +1
@export_range(0.0, 20.0, 0.1) var count := 1.0
## 选址是否偏好主街临街大地块
@export var prefer_main_street := true
## 专属户型模板（门字符 G 画在最底边墙上）；空 = 回退 CityDef.houses
@export var templates: Array[TemplateDef] = []

func _to_string() -> String:
	return "Facility[%s x%.1f]" % [facility_name, count]
