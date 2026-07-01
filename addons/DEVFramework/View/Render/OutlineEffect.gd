@tool
class_name OutlineEffect extends CompositorEffect
## 选中物体描边后处理（单类，零外部依赖）
##
## 原理：
##   set_outlined(node,true) → MeshInstance3D.material_overlay = 标记材质
##   blend_add → 选中像素 alpha 从 1.0 累加到 2.0（HDR 缓冲可存储 >1）
##   compute shader → 检测 alpha > 1.5 → 8方向膨胀 → 描边合成
##
## 优化要点：
##   - 无选中物体时完全跳过 GPU dispatch
##   - shader 一次性编译，永不重编（参数全部走 push constant）
##   - 多循环缓存避免每帧分配


#region --- 导出属性 ---

@export_group("Outline", "outline_")
@export var outline_color := Color(1.0, 0.85, 0.2, 1.0)
@export var outline_width := 2.0
@export var outline_alpha := 1.0

const MARKER_THRESHOLD := 1.5   # normal=1.0，marked=2.0，阈值取中间

#endregion


#region --- 静态标记管理 ---

static var _outlined_dict: Dictionary = {}   # main-thread dedup
static var _outlined_count: int = 0          # render-thread safe
static var _overlay_mat: ShaderMaterial
static var _mesh_cache: Dictionary = {}      # {instance_id: Array[MeshInstance3D]}


static func set_outlined(node: Node, on: bool) -> void:
	if not node or not is_instance_valid(node):
		return
	var id := node.get_instance_id()
	if on:
		if id in _outlined_dict:
			return
		_outlined_dict[id] = true
		_outlined_count += 1
		if not node.tree_exiting.is_connected(_on_node_free.bind(id)):
			node.tree_exiting.connect(_on_node_free.bind(id), CONNECT_ONE_SHOT)
	else:
		if not _outlined_dict.erase(id):
			return
		_outlined_count -= 1
		if _mesh_cache.has(id):
			_mesh_cache.erase(id)

	var meshes: Array = _get_cached_meshes(node, id)
	var mat: ShaderMaterial = _get_overlay_mat() if on else null
	for m in meshes:
		var mi := m as MeshInstance3D
		if not mi:
			continue
		mi.material_overlay = mat


static func _on_node_free(id: int) -> void:
	if not _outlined_dict.erase(id):
		return
	_outlined_count -= 1
	_mesh_cache.erase(id)


static func _get_cached_meshes(node: Node, id: int) -> Array:
	if _mesh_cache.has(id):
		return _mesh_cache[id]
	var meshes := node.find_children("*", "MeshInstance3D", true, false)
	_mesh_cache[id] = meshes
	return meshes


static func _get_overlay_mat() -> ShaderMaterial:
	if _overlay_mat and _overlay_mat.shader:
		return _overlay_mat
	_overlay_mat = ShaderMaterial.new()
	_overlay_mat.shader = _make_marker_shader()
	return _overlay_mat


static func _make_marker_shader() -> Shader:
	var s := Shader.new()
	# blend_add: finalColor = srcColor*srcAlpha + dstColor = (0,0,0)*1 + dst = dst（不变）
	#            finalAlpha = srcAlpha     + dstAlpha = 1       + 1   = 2.0（标记）
	s.code = """shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_test_disabled, shadows_disabled;
void fragment() { ALBEDO = vec3(0.0); ALPHA = 1.0; }"""
	return s

#endregion


#region --- 渲染管线 ---

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var _compiled := false


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	rd = RenderingServer.get_rendering_device()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and shader.is_valid():
		RenderingServer.free_rid(shader)


func _ensure_shader() -> bool:
	if _compiled:
		return pipeline.is_valid()
	if not rd:
		return false

	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = COMPUTE_SHADER
	var spv := rd.shader_compile_spirv_from_source(src)
	if spv.compile_error_compute != "":
		push_error("[OutlineEffect] ", spv.compile_error_compute)
		_compiled = true  # 避免反复报错
		return false

	shader = rd.shader_create_from_spirv(spv)
	if not shader.is_valid():
		_compiled = true
		return false

	pipeline = rd.compute_pipeline_create(shader)
	_compiled = true
	return pipeline.is_valid()


func _render_callback(p_type: EffectCallbackType, p_data: RenderData) -> void:
	if _outlined_count <= 0 or outline_width <= 0.0:
		return
	if not rd or p_type != effect_callback_type or not _ensure_shader():
		return

	var bufs: RenderSceneBuffersRD = p_data.get_render_scene_buffers()
	var sd: RenderSceneData = p_data.get_render_scene_data()
	if not bufs or not sd:
		return

	var size := bufs.get_internal_size()
	if size.x == 0 and size.y == 0:
		return

	@warning_ignore("integer_division")
	var gx := (size.x - 1) / 8 + 1
	@warning_ignore("integer_division")
	var gy := (size.y - 1) / 8 + 1

	var pc := PackedFloat32Array([
		outline_width,
		outline_alpha,
		MARKER_THRESHOLD,
		0.0,  # _pad（16字节对齐）
		outline_color.r,
		outline_color.g,
		outline_color.b,
		outline_color.a,
	])

	for view in bufs.get_view_count():
		var set_rid := UniformSetCacheRD.get_cache(shader, 0, [
			_rd_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, bufs.get_color_layer(view)),
		])
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, pipeline)
		rd.compute_list_bind_uniform_set(cl, set_rid, 0)
		rd.compute_list_set_push_constant(cl, pc.to_byte_array(), 32)
		rd.compute_list_dispatch(cl, gx, gy, 1)
		rd.compute_list_end()


static func _rd_uniform(type: int, bind: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = type
	u.binding = bind
	u.add_id(rid)
	return u

#endregion


#region --- 计算着色器 ---

const COMPUTE_SHADER := """#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set=0, binding=0) uniform image2D color_image;

layout(push_constant, std430) uniform Params {
	float outline_width;
	float outline_alpha;
	float marker_threshold;
	float _pad;              // vec4 对齐所需填充
	vec4 outline_color;
} params;

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(color_image);
	if (uv.x >= size.x || uv.y >= size.y)
		return;

	vec4 color = imageLoad(color_image, uv);

	float marked = float(color.a > params.marker_threshold);
	float dilated = marked;

	int w  = int(params.outline_width);
	int wd = int(params.outline_width * 0.707);
	ivec2 nuv;

	if (w > 0) {
		// 4方向（上下左右）
		nuv = uv + ivec2( w,  0);
		if (all(greaterThanEqual(nuv, ivec2(0))) && all(lessThan(nuv, size)))
			dilated = max(dilated, float(imageLoad(color_image, nuv).a > params.marker_threshold));
		nuv = uv + ivec2(-w,  0);
		if (all(greaterThanEqual(nuv, ivec2(0))) && all(lessThan(nuv, size)))
			dilated = max(dilated, float(imageLoad(color_image, nuv).a > params.marker_threshold));
		nuv = uv + ivec2( 0,  w);
		if (all(greaterThanEqual(nuv, ivec2(0))) && all(lessThan(nuv, size)))
			dilated = max(dilated, float(imageLoad(color_image, nuv).a > params.marker_threshold));
		nuv = uv + ivec2( 0, -w);
		if (all(greaterThanEqual(nuv, ivec2(0))) && all(lessThan(nuv, size)))
			dilated = max(dilated, float(imageLoad(color_image, nuv).a > params.marker_threshold));
		// 4对角线（wd = w × 0.707）
		nuv = uv + ivec2( wd,  wd);
		if (all(greaterThanEqual(nuv, ivec2(0))) && all(lessThan(nuv, size)))
			dilated = max(dilated, float(imageLoad(color_image, nuv).a > params.marker_threshold));
		nuv = uv + ivec2( wd, -wd);
		if (all(greaterThanEqual(nuv, ivec2(0))) && all(lessThan(nuv, size)))
			dilated = max(dilated, float(imageLoad(color_image, nuv).a > params.marker_threshold));
		nuv = uv + ivec2(-wd,  wd);
		if (all(greaterThanEqual(nuv, ivec2(0))) && all(lessThan(nuv, size)))
			dilated = max(dilated, float(imageLoad(color_image, nuv).a > params.marker_threshold));
		nuv = uv + ivec2(-wd, -wd);
		if (all(greaterThanEqual(nuv, ivec2(0))) && all(lessThan(nuv, size)))
			dilated = max(dilated, float(imageLoad(color_image, nuv).a > params.marker_threshold));
	}

	float outline = dilated - marked;
	float blend = outline * params.outline_alpha * params.outline_color.a;
	color.rgb = mix(color.rgb, params.outline_color.rgb, blend);

	// 不恢复 alpha：标记仅本帧有效，下帧 overlay 重新写入
	imageStore(color_image, uv, color);
}"""

#endregion
