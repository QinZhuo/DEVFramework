@tool
class_name DioramaSkin
extends RefCounted
## 一幅 diorama 的「配色契约」基类 —— 让演示场景不必认识任何具体用例
##
## ## 为什么需要这一层
## [DioramaPresets] 给的是"摆什么、摆哪"，而"这一幅画用什么颜色"是另一件事：
## [VoxelSkin]（用例四）用一套静态表，新用例若照抄就得把 static 方法再写一遍，
## 且演示场景每加一个用例都要多一行 `if preset_key == ...`。
## 这里把配色收成**可实例化的对象**，演示场景只认
## [method palette] / [method material_provider] 两个方法，与用例无关。
##
## ## 纪律
## · 子类必须覆写 [method palette] 与 [method material_provider]：
##   前者给 [SceneStylePack] 级别的画风装配，后者给 [method DioramaBuilder.spawn]
##   的逐索引取色（**体素之外的形态拿不到部位色**，见派生类的说明）。
## · 色板顺序必须与索引常量一一对应：提取器按索引取色，错位即错色且不报错。
## · 0 号留给主体色，并且每个生成器都以覆盖全包围盒的「兜底区」收尾 ——
##   理由见 [VoxelSkin] 文件头（这条对全部用例成立，不是用例四的特例）。


## 该幅 scenario 的标题，供 UI 显示。
var title := "微缩场景"


## 固定 swatch 色板。`[0]` 应当是该幅画的主体色，因为它同时是未命中时的兜底色。
func palette() -> ToonPaletteDef:
	var p := ToonPaletteDef.new()
	p.resource_name = title
	return p


## 逐调色板索引取色的材质提供者，`func(palette_index: int, face_dir: int) -> Material`。
##
## 默认实现走 [method ToonMaterial.voxel_material_provider] —— 它是**体素产物**的正规出口
## （[member DioramaRecipe.Form] 为 VOXEL_* 时逐 surface 挂不同材质）。
## MESH 形态的网格是**单 surface**，"分件色"这件事在几何层面已经不存在了，
## 此时 provider 只会给到 surface 0 —— 画面照样出图、不报错，但整件一种颜色。
## 这就是各用例都必须走体素形态的原因（用例二的"低多边形"也不例外）。
func material_provider(style: ToonStyleDef) -> Callable:
	return ToonMaterial.voxel_material_provider(style, palette())


## 覆写 base/shade/deep/outline 四个 ramp 语义色。
##
## 保留 ramp 语义是必要的：虽然色阶档数、暗部染色、轮廓光、雾都来自 [ToonStyleDef]，
## 但 swatch 色板本身并不携带"这套配色的暗部是什么"——
## 少了这四个锚点，[ToonMaterial] 的 tinted 分支会退回手挑的单色档位。
func apply_ramp(p: ToonPaletteDef, base: Color, light: Color,
		shade: Color, deep: Color, outline: Color) -> ToonPaletteDef:
	p.base = base
	p.light = light
	p.shade = shade
	p.deep = deep
	p.outline = outline
	return p
