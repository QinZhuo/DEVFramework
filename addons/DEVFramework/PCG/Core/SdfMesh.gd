class_name SdfMesh
extends RefCounted
## 等值面提取结果 — 纯数据（顶点/法线/索引），可转 ArrayMesh 或继续加工
##
## 法线来自 SDF 梯度而非面法线平均：这是 SDF 做三渲二硬边的关键
## （面法线平均会把棱角圆化，梯度法线按等值面分段，保住棱线）。

var vertices := PackedVector3Array()
var normals := PackedVector3Array()
var indices := PackedInt32Array()
## 提取时的场局部坐标包围盒（相对 field.origin）
var local_aabb := AABB()

func triangle_count() -> int:
	return indices.size() / 3

func vertex_count() -> int:
	return vertices.size()

func is_empty() -> bool:
	return indices.is_empty()

## 转 Godot 原生 ArrayMesh（直接构造 arrays，热路径不走逐点 API）
func to_arraymesh(material: Material = null) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if vertices.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if material:
		mesh.surface_set_material(0, material)
	return mesh

## 统计信息（对比测试台用）
func stats() -> Dictionary:
	return {"vertices": vertices.size(), "triangles": triangle_count()}
