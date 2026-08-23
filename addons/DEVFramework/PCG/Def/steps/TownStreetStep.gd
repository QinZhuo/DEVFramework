@tool
class_name TownStreetStep extends TownStepDef
## 街具 — 路灯沿主干道/环路间隔取样贴路边；长椅沿广场临路边缘间隔摆放

## 路灯间隔（格）
@export_range(2, 16, 1) var streetlamp_spacing := 6


func apply(ctx: TownGenContext) -> void:
	PCGTool.town_street_step(self, ctx)
