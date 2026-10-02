@tool
class_name VoxelSkinPack
extends DioramaSkin
## 用例四「体素面包店街角」的皮肤适配器
##
## [VoxelSkin] 是**静态**表（`VoxelSkin.palette()` 这种写法），它早于本基类存在、
## 且有 9 个生成器直接引用它的常量，改签名要动一大片。
## 于是加一层适配器：把静态表包成 [DioramaSkin] 的实例形态，两边都不用改。
##
## 这是个纯粹的转发层，**不含任何新的美术判断** —— 色值仍然只有 [VoxelSkin] 一处。

func _init() -> void:
	title = "用例四 · 体素面包店街角"


func palette() -> ToonPaletteDef:
	return VoxelSkin.palette()


func material_provider(style: ToonStyleDef) -> Callable:
	return VoxelSkin.material_provider(style)
