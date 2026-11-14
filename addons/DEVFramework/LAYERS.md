# 分层约定（框架 = 机制 / 项目 = 内容）

> 新增任何代码前先过第二节清单。历史决策见第八节。

## 一、核心原则

- 框架（`addons/DEVFramework/`）：换一款游戏仍成立的数学、结构、协议、管线。
- 项目（`Scripts/`、`Assets/`）：只对当前游戏成立的玩法规则、数值语义、资源、文案。
- Def 的身份 = 资源路径（存档只存路径，DLC 靠同路径覆盖）。

## 二、归属判定（按序自问，命中即停）

| # | 问题 | 是 → |
|---|---|---|
| 1 | 换个游戏这段代码一字不改还能用？ | 框架 |
| 2 | 去掉具体语义后剩一个通用骨架？ | 骨架进框架，具体实现在项目 |
| 3 | 引用具体项目资源或类？ | 项目 |
| 4 | 含游戏语义（伤害公式、存档字段、联机策略）？ | 项目 |
| 5 | 纯数学 / 纯结构（状态机、修饰符计算、序列化协议）？ | 框架 |

## 三、三种合法协作

1. **继承扩展**：项目 `extends` 框架基类（`DamageEffectDef extends EffectDef`）。
2. **组合调用**：项目调框架工具（`SaveTool.save_async`、`NodeTreeTool.game_ready`）。
3. **鸭子回调**：框架侧参数不带类型，或由项目注入 `Callable`。框架永不 `load` 项目脚本。

## 四、红线

| # | 禁止 |
|---|---|
| 1 | 框架代码出现项目资源路径默认值 |
| 2 | 框架类型注解 / 导入项目类 |
| 3 | 游戏策略（联机权限、存档格式）写死在框架组件里 |
| 4 | 框架注释用项目专属类名举例 |

口诀：**路径、类型名、策略、注释，四处都不要让框架认识项目。**

## 五、目录双轨制

| 轨道 | 目录 | 放什么 |
|---|---|---|
| 分层轴 | `Def/` `Entity/` `View/` `Tool/` 根部 | 被所有功能共用的基类协议、纯数学原语、横切工具 |
| 功能轴 | `<Module>/{Def,Entity,Tool,View}/` 自包含 | 可拔插功能域：AI、ECS、Task、GameCommand、Tween、Camera |

归属三问：**删除测试**（整文件夹删掉还能编译？）→ **API 宽度**（少量入口类，还是被广泛继承）→ **共变率**（是否总一起改）。
红线：同一功能域的 Def 与 Entity 不许劈到两处；跨模块依赖单向且显式（现存两条：`Entity/Component → ECS`、`MCP → Camera`）。

**已知偏差**：`ECS/` 被 `Entity`/`Component` 内建桥接（`ECSLink` 类型注解），实际扮演核心层，删除测试对它不成立 ——
要么抽成可选桥接，要么正式归入分层轴，不要让文档与代码各说各话。

## 六、违规自查

```powershell
grep -rE "res://(Scripts|Assets|Scenes)/" addons/DEVFramework --include="*.gd"
grep -rE "\b(damage|card|fight|buff|health|gold|shop)\b" addons/DEVFramework --include="*.gd"
```

改/删共享资源前先查引用（MCP `find_resource_users`）；移动脚本连 `.gd.uid` 一起 `git mv`。

## 七、Def 寻址（路径即身份）

| # | 纪律 | 违反后果 |
|---|---|---|
| 1 | 不改名、不移动已有 Def 文件 | 老存档路径失效，读取返回 null |
| 2 | 同一路径只换实现，不换语义 | 老存档静默读到另一份配置 |
| 3 | 关键存档数据不用内嵌子资源 | 无法被 DLC 覆盖，子资源改名/重排即失效 |

新增内容一律用新路径（覆盖只用于替换，不用于扩展）。

## 八、决策记录

- **2026-11** ECS 系统改为纯运行时（`RefCounted`，`World._setup_world` 里代码创建并注册），不继承 Def、无配置资源层；`register_system()` 不传优先级时取 `system.priority`。
- **2026-10** PCG 拆为独立插件项目（`d:\Work\GodotProject\PCG`）；程序化音频合成整体移除。
- **2026-08** Buff/Attribute 下沉项目层（框架只留 `Modifier`/`ModifierValue` 数学）。
- **2026-08** VirtualCamera 并入框架 `Camera/` 功能轴（机位竞争 + 混合数学 + 行为资源）。
- **2026-08** Task/Audio 归位功能轴，确立目录双轨制。
