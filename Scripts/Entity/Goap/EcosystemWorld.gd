class_name EcosystemWorld extends RefCounted
## 生态箱世界常量与工具 — 统一世界边界与随机位置生成。

const WORLD_RECT := Rect2(44.0, 44.0, 1064.0, 552.0)


static func rand_pos() -> Vector2:
	return Vector2(
		randf_range(WORLD_RECT.position.x, WORLD_RECT.end.x),
		randf_range(WORLD_RECT.position.y, WORLD_RECT.end.y)
	)


static func clamp_pos(p: Vector2) -> Vector2:
	return Vector2(
		clampf(p.x, WORLD_RECT.position.x, WORLD_RECT.end.x),
		clampf(p.y, WORLD_RECT.position.y, WORLD_RECT.end.y)
	)
