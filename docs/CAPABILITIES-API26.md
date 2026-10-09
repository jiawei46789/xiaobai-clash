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
- **互动卡片**：新增 `extensionAbilities` 条目 `type: "liveForm"` + 实现
  `LiveFormExtensionAbility` + `$profile:form_config`（参考官方「实况窗/互动卡片」指南）。
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