# 能力接入说明 · API 26 升级（1.6.22）

本文记录本工程「视觉 AI / 3DGS 重建 / 沉浸光感组件 / 互动卡片 / 闪控窗」五类能力的
**依赖与权限声明**现状，以及 API 26 升级的实际改动与验证结论。
（本轮范围：只升 API + 加依赖/权限声明，不落 UI 代码。）

## 一、本次改动

| 文件 | 改动 |
|---|---|
| `build-profile.json5` | `compatibleSdkVersion` `6.1.1(24)` → `26.0.0`（`targetSdkVersion` 维持 `26.0.0`） |
| `entry/src/main/module.json5` | 新增权限声明：`CAMERA` / `ACCELEROMETER` / `GYROSCOPE` / `VIBRATE` |
| `entry/src/main/resources/base/element/string.json` | 新增上述权限的 `reason` 文案 |
| `AppScope/app.json5` | 版本 `1.6.21` → `1.6.22`（versionCode 106022） |

### 两个实锤坑

1. **hvigor 不接受平台格式版本号**：`compatibleSdkVersion: "7.0.0(26)"` 会直接报
   `api version parameter is illegal! Expected format: <major>[.<minor>][.<patch>]`。
   必须用数字点分格式 `"26.0.0"`（等价于平台 7.0.0(26)）。
2. **系统级权限不能直接声明**：`FLOAT_VIEW` / `USE_FLOAT_BALL` 属于 `system_basic`，
   本工程签名 profile 的 APL 为 `normal` 且 `acls` 为空。把它们写进 `requestPermissions`
   会导致 **整包安装失败**：`code:9568289 install failed due to grant request permissions failed.
   PermissionName: ohos.permission.FLOAT_VIEW`（真机实测）。故本工程**不声明**这两项。

## 二、五类能力 → SDK / 权限映射

| 能力 | SDK 模块 | Kit | 起始版本 | 所需权限 | 本工程可用性 |
|---|---|---|---|---|---|
| **沉浸光感组件** | `@hms.hds.hdsBaseComponent`（`HdsNavigation` / `HdsTabs` / `HdsListItemCard` …）+ `@hms.hds.hdsMaterial`（`MaterialType.ADAPTIVE`） | UIDesignKit | 6.1.0(23) | 无 | ✅ API26 满足，可直接 import |
| **互动卡片** | `@ohos.app.form.LiveFormExtensionAbility`（extensionAbility `type: "liveForm"`） | FormKit | 20 | 无 | ✅ 需补 liveForm 扩展 + `form_config` |
| **闪控窗** | `@ohos.window.floatView`（+ `@ohos.window.floatingBall` 闪控球） | ArkUI | 26.0.0 | `FLOAT_VIEW`(user_grant, system_basic)、`USE_FLOAT_BALL`(system_grant, system_basic) | ⚠️ 需带 acls 的 system_basic profile，否则装机即失败 |
| **视觉 AI** | `@hms.ai.visionImageAnalyzer` / `@hms.ai.vision.*`（imageSuperResolution / objectDetection / skeletonDetection / subjectSegmentation / textSearchImage） | VisionKit | 5.0.0(12) | `CAMERA`（取图场景） | ✅ 已声明 CAMERA |
| **3DGS 重建** | `@hms.graphics.spatialRender`（渲染）、`@hms.graphics.spatialEdit`（编辑） | SpatialReconKit | 6.0.1(21) / 26.0.0(编辑) | 姿态用 `ACCELEROMETER`/`GYROSCOPE` | ✅ API26 满足 |

> 注：感官反馈类能力（沉浸光感、互动卡片点击）可用 `VIBRATE`（已声明，system_grant）。

## 三、需要真正启用时的做法

- **沉浸光感**：`import { HdsNavigation, HdsTabs, HdsTabsController } from '@kit.UIDesignKit'`；
  底部页签用 `HdsTabs`，在 `barFloatingStyle.systemMaterialEffect` 配
  `materialType = hdsMaterial.MaterialType.ADAPTIVE`。

  ⚠️ **`.systemMaterial()` 有作用域限制（实测坑）**：该属性只在「导航标题栏组件 /
  TabBar」内生效，挂在普通 `Row`/`Column` 上会被运行时判为 inert，**编译不报错、
  看着设置了但什么都没渲染**，只在日志里留一行：

  ```
  W C03900/Ace: Material inactive: out of scope. Use component in navigation title bar or Tabbar.
  ```

  普通容器要做磨砂质感请用 `.backgroundBlurStyle(BlurStyle.COMPONENT_*)`（无作用域限制）。
  排查手法：`hilog | grep -c 'Material inactive'`，应为 0。
- **互动卡片**：新增 `extensionAbilities` 条目 `type: "liveForm"` + 实现
  `LiveFormExtensionAbility` + `$profile:form_config`（参考官方「实况窗/互动卡片」指南）。

### HdsTabs 底部悬浮栏：三个实测坑

已在 1.6.25 真机（MIA-AL00 / API 26 / HarmonyOS 7.0.0.109）跑通，形态为
「底部悬浮磨砂胶囊 + 内容从栏下滑过 + 标题栏磨砂」，与商店主流 App 一致。

1. **`barPosition` 必须写在构造参数里**，不能用 `.barPosition()` 属性设置器。
   HDS_tabs 从 options 读取它，走属性会报：
   ```
   E HDS_tabs: GetTabBarPosition barPosition is not a number
   ```
   正确写法：`HdsTabs({ index: i, controller: c, barPosition: BarPosition.End })`

2. **`barSideMargin` / `barBottomMargin` 在当前 SDK+设备组合下不生效**。
   两者声明类型是 `Length`，但实测传裸数字（`12`）和带单位字符串（`'12vp'`）
   **都会**被解析器拒绝：
   ```
   W HDS_tabs: ParseProp failed parse property barSideMargin
   W HDS_tabs: ParseProp failed parse property barBottomMargin
   ```
   伴随 `!fsTabBarHandler_` 与 `hmos_hds_tab_pattern get attr tab_bar_mask_color_default error!`。
   与其留一行无效配置加错误注释误导后人，**不如直接不传**，用 HDS 默认边距 ——
   实测默认值已足够：胶囊 `x=58..1166`（屏宽 1224，左右各内缩 ~58px）、
   `y=2493..2682`（底部留白 ~94px）。

3. **`scrollable(false)` 是刻意的**，不是遗漏。页内已有大量手势
   （节点列表滚动、视觉页 3D 球的 PanGesture 旋转），开启左右滑动切页会与
   它们抢手势，导致 3D 转不动。9 个入口靠 `barMode(BarMode.Scrollable)`
   在栏内横向滚动解决。

另外记一条 ArkTS 通用坑：**成员名不能叫 `tabIndex`** —— `CustomComponent` 基类
已有同名成员，撞名会编译失败（`Property 'tabIndex' ... is not assignable to the same
property in base type 'CustomComponent'`）。本工程改用 `navIndex`；同类既有教训是
NodesPage 里不能叫 `toolbar`。
- **闪控窗**：先在 AGC 重新申请带 `acls: ["ohos.permission.FLOAT_VIEW","ohos.permission.USE_FLOAT_BALL"]`
  的调试/发布 profile（system_basic 级），替换 `com_xiaobai_clash.p7b` 后，再在 `module.json5`
  声明这两项权限，方可使用 `floatViewController.start()`。
- **视觉 AI / 3DGS**：直接 `import` 对应 HMS kit；需真机具备 syscap
  `SystemCapability.AI.VisionImageAnalyzer` / `SystemCapability.Graphics.SpatialRender` / `SpatialEdit`。

## 四、验证记录（真机 MIA-AL00 · API 26 · HarmonyOS 7.0.0.109）

- `compatibleSdkVersion = "26.0.0"` + 7 项权限 → `hvigor assembleHap` **BUILD SUCCESSFUL**。
- 产物 HAP 内 `pack.info` / `module.json`：version 1.6.22，权限列表含 CAMERA/ACCELEROMETER/GYROSCOPE/VIBRATE。
- 装载：`install bundle successfully`；启动 `pidof com.xiaobai.clash` 有进程。
- 负路径：带 `FLOAT_VIEW` 声明时 → `code:9568289`（故已移除，见上）。

## 五、1.6.24 实际落地情况

上一节是「声明就绪」；本节是真正写进代码并装机验证过的部分。

### 已落地（可在应用内直接使用）

| 能力 | 实现 | 位置 |
|---|---|---|
| 交互 3D | ArkGraphics3D `Scene.load()` 空场景 + 内置 `SphereGeometry`（不依赖外部 glTF 资源）；`Component3D` 承载；PanGesture 旋转 / PinchGesture 缩放；球体体积由本次会话真实累计流量驱动，链路异常时压扁告警 | `services/Scene3D.ets`、`pages/VisualPage.ets` |
| 沉浸光感（应用外壳） | 底部悬浮页签栏 `HdsTabs` + `barFloatingStyle.systemMaterialEffect`（`hdsMaterial.MaterialType.ADAPTIVE` / `MaterialLevel.ADAPTIVE`，按设备算力自适应）；`barOverlap(true)` 让内容从栏下滑过；标题栏用 `.backgroundBlurStyle(COMPONENT_REGULAR)` 磨砂并浮在内容之上（Stack 布局）。**这是真正生效的沉浸光感** | `pages/Index.ets` |
| 磨砂材质档位 | `.backgroundBlurStyle()`，点击循环 ULTRA_THIN/THIN/REGULAR/THICK/ULTRA_THICK 五档；`getGlobalMaterialLevel()` / `isImmersiveMaterialSupported()` 做能力探测并显示设备档位 | `pages/VisualPage.ets` |
| HDS 视觉组件 | `HdsVisualComponent` + `HdsSceneController` 双边流光（`DUAL_EDGE_FLOW_LIGHT_WITH_BACKGROUND_MASK`） | `pages/VisualPage.ets` |
| 小艺智能体 | `@InsightIntentEntry` 注册意图 `ControlVpn`（ToolsDomain / foreground）；`@InsightIntentEntity` 定义返回体 | `intents/VpnIntentEntry.ets` |

**降级策略**：`isImmersiveMaterialSupported()=false` 或 3D 构建失败时，材质卡退回普通底色、
3D 区显示提示文案，页面其余部分照常可用 —— 3D/材质不可用绝不能影响 VPN 主功能。

### 小艺意图的设计取舍

执行器**不直接开关 VPN**，而是把动作写进 AppStorage 信箱（`intentVpnAction`），由 Index 页
读取后走既有 `toggleVpn()`。理由：

- 意图执行器与主界面不在同一 UI 上下文，直接操作会造出第二条能开关隧道的路径；
- 本工程自 1.6.2 起有硬约束「VPN 只允许手动开/关」，自动连接路径已全部切断；
- 因此 `disconnect` 直接执行（关隧道无风险），`connect` 只把界面带到首页并提示一键连接，
  由用户点按确认。

编译期证据（比口头声明可靠）：装饰器会生成真实清单
`resources/base/profile/insight_intent.json`，内含 `intentName: ControlVpn`、
`executeMode: ["foreground"]`、`abilityName: EntryAbility`、parameters/result schema、
以及 `entities[].entityId: vpn-control`。装饰器写错会直接编译失败，不会静默失效。

注意：`@InsightIntentEntry` 修饰的类必须 `export default`，且**类属性只能是基础类型或意图实体**
（所以入参用 `action: string`，不能用枚举/对象），返回值必须是 `IntentResult<实体>`。

### 真机验证证据

- 导航新增「视觉」页签渲染正常；`Scene3D: scene built` + `VisualPage: 3d scene ready` 日志在位。
- 拖动 3D 区域：`偏航 0° → 34°`（旋转生效）。
- 连点材质卡 3 次：档位标签 `常规 → 极薄`（五档循环并正确回绕）。
  ⚠️ 补记：这一条是在**旧写法**（`.systemMaterial()`）下测的，当时只证明了
  `styleIndex` 数字在变 —— 而那个 API 在普通 Column 上是 inert 的，**材质根本没渲染**。
  1.6.25 已改为 `.backgroundBlurStyle()`，档位差异现在真实可见。
  教训：UI 状态数字变了 ≠ 视觉效果生效，必须查运行时日志确认（见下）。
- 点「播放」触发流光，进程 pid 不变、无 JsError/crash（未崩溃）。
- 设备材质档位实测为「柔和」（GENTLE），沉浸材质可用。
- 小艺意图：`insight_intent.json` 清单生成正确（见上）。

### 仍未接入（按 1.6.22 的范围约定，只声明未实现）

视觉 AI（VisionKit）、3DGS 重建（SpatialReconKit）、互动卡片（LiveForm）、闪控窗。
其中闪控窗有平台级阻断（`FLOAT_VIEW`/`USE_FLOAT_BALL` 为 system_basic，需带 acls 的 profile，
直接声明会导致整包安装失败 `code:9568289`）。接入步骤见第三节。

## 六、1.6.25 导航壳重构：底部悬浮沉浸光感页签栏

需求：「沉浸光感学其他软件的设计」。主流 App 的形态不是「往卡片上贴材质」，
而是**把材质做在应用外壳上**：底部悬浮磨砂页签栏 + 内容从栏下滑过 + 标题栏磨砂。

### 改动

- `Index.ets` 外壳由 `Column{header, nav(横向按钮排), pageContent}` 改为
  `Stack{ Column{ HdsTabs(9 个 TabContent) }, header }`；
- 删除旧 `nav()` 横向按钮排，9 个入口全部进底部悬浮栏（`barMode(Scrollable)` 横向滚动）；
- 标题栏改用 `.backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR)` 并浮在内容之上
  （`padding({top: HEADER_H})` 让内容从其下方滑过，磨砂才有内容可取）；
- `VisualPage` 的材质卡由失效的 `.systemMaterial()` 改为 `.backgroundBlurStyle()`。

### 为什么标题栏不用 systemMaterial

实测日志给出的硬约束：

```
W C03900/Ace: Material inactive: out of scope.
  Use component in navigation title bar or Tabbar.
```

`.systemMaterial()` 只在「导航标题栏组件 / TabBar」内生效。本工程的标题栏是个普通
`Row`（不是 `HdsNavigation` 的 TitleBar），所以挂上去是 **inert**：编译通过、不报错、
什么都不渲染。真正生效的只有底部 `HdsTabs` 的 `systemMaterialEffect`（它是 Tabbar）。

因此：TabBar 用 `systemMaterialEffect`（真沉浸光感），标题栏/普通容器用
`backgroundBlurStyle`（无作用域限制，同样有磨砂质感）。

### 真机验证证据（MIA-AL00 · API 26 · HarmonyOS 7.0.0.109）

运行时日志（修复前后对照，这是唯一可信的判据）：

| 指标 | 修复前 | 修复后 |
|---|---|---|
| `grep -c 'Material inactive'` | 1（标题栏+材质卡都 inert） | **0** |
| `grep -cE 'ParseProp failed\|barPosition is not a number'` | 3 | **0** |
| JsError / crash / Fault | 无 | 无 |

几何证据（`uitest dumpLayout`，屏宽 1224 / 高 2776）：

- `TabBar bounds=[58,2493][1166,2682]` —— 左右各内缩 ~58px、底部留白 ~94px，
  确为悬浮胶囊而非贴底通栏；
- 9 个页签文本全部落在 `y=2571`，`设置` 项 `selected="true"`；
- 内容行（如「核心版本」`y=2601..2648`）落在 TabBar 的 y 区间内 —— 证明
  `barOverlap(true)` 生效，内容确实从栏下方滑过。

交互证据：逐个点击 6 个页签（视觉/规则/应用/设置/节点/连接），标题栏标题
**6/6 全部跟随切换正确**。

> 排查备忘：验证脚本一度报 6/6 MISMATCH，是**脚本自身**的假阴性 ——
> PS 5.1 以 ANSI/GBK 读取 BOM-less UTF-8，把脚本里写的「视觉」变成「瑙嗚」，
> 而设备回读的标题（UTF-8 读）是正确的「视觉」，两者比对必然不等。
> 这正是本工程 `publish-update.ps1` 里早就记下的同一个坑：
> **PS 脚本内的中文注释/字面量必须存成带 BOM 的 UTF-8，或干脆只用 ASCII**。

## 七、订阅下载 403 的真实成因（排查记录）

用户报「导入配置报 HTTP 403」。排查过程值得留存，因为**第一直觉是错的**：

1. 先怀疑面板 WAF 挑 UA → 加了 UA 回退链。装机后界面报
   `订阅下载失败：[object Object]`，说明错误被吞了。
2. 定位到吞错误的原因：HarmonyOS 网络栈抛的是 `BusinessError`，**不是 `Error` 实例**，
   `instanceof Error` 为 false，`String(err)` 得到 `[object Object]`，真实错误码丢失。
3. 修好错误透传后，真机日志给出真相：`fetch network error: 2300999 Internal error`。
   PC 侧 curl 同一域名报 `schannel: failed to receive handshake` / connection reset。
4. 结论：**不是 UA 问题，也不是面板回 403**，而是机场域名在 Cloudflare 后面，
   大陆直连在 TLS 握手阶段就被 SNI 重置，压根拿不到 HTTP 状态码。
5. 因此真正的修复是**内核本地代理兜底**：直连失败时改走 mihomo 混合端口
   `127.0.0.1:7890`（`usingProxy` 显式指定，不依赖 TUN 透明接管）。

### 验证手法（可复用）

设备无 curl，但可以反向利用 hdc 端口转发做 A/B 对照：

```powershell
# 把设备的 mihomo 混合端口暴露到 PC（fport = PC→设备，方向别搞反）
hdc -t <target> fport tcp:17890 tcp:7890
curl.exe -x http://127.0.0.1:17890 -A "lian-connect/0.01" -D hdr.txt -o body.txt <订阅URL>
```

实测结果：直连 `code=200`（该机场域名当时可达）、经设备代理 `code=200 / 30376 字节`，
两条路径都通 —— 代理兜底链路本身工作正常。

另一个关键发现：该机场**两种响应都没有 `subscription-userinfo` 头**，
所以 1.6.21 的流量识别对它显示「该订阅未提供流量信息」是正确行为，不是 bug。

### 顺带修掉的性能坑

旧逻辑在网络层异常时会拿 10 个 UA 各等 30 秒 —— 死链导入能卡住几分钟。
现在网络层错误码（SNI 重置/DNS/TLS/超时）立刻结束本轮并切换链路。