/**
 * 视觉页：交互 3D + 沉浸光感。
 *
 * 三块能力，全部由**真实运行数据**驱动，不做模拟：
 *  1) 交互 3D —— ArkGraphics3D 的 Scene + 内置球体几何，PanGesture 拖动旋转、
 *     PinchGesture 双指缩放；球体大小随本次会话累计流量增长，链路异常时压扁。
 *  2) 沉浸光感 —— API 26 的 `.systemMaterial()` + `uiMaterial.ImmersiveMaterial`，
 *     点击卡片可循环 ULTRA_THIN→THIN→REGULAR→THICK→ULTRA_THICK 档位。
 *  3) HDS 流光 —— `HdsVisualComponent` 双边流光场景（UIDesignKit）。
 *
 * 设备算力不足时（isImmersiveMaterialSupported()=false 或 3D 构建失败）自动降级：
 * 材质卡片退回普通底色、3D 区显示提示文案，页面其余部分照常可用。
 */
import { ContentFrame } from '../common/ContentFrame';
import { Fmt } from '../common/Format';
import { uiMaterial } from '@kit.ArkUI';
import { Scene } from '@kit.ArkGraphics3D';
import {
  HdsVisualComponent,
  HdsSceneType,
  HdsSceneController,
  hdsEffect
} from '@kit.UIDesignKit';
import { Scene3D, Scene3DHandle } from '../services/Scene3D';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x2032;
const TAG = 'VisualPage';

/** 沉浸光感档位（与 uiMaterial.ImmersiveStyle 一一对应，用于循环切换） */
const STYLE_LABELS: string[] = ['极薄', '薄', '常规', '厚', '极厚'];

@Component
export struct VisualPage {
  /** 本次会话累计下行字节（真实值，来自核心心跳） */
  @Prop downTotal: number = 0;
  /** 本次会话累计上行字节 */
  @Prop upTotal: number = 0;
  /** 链路健康状态：ok / fail / unknown */
  @Prop healthState: string = 'unknown';
  /** 当前出口节点名，显示在 3D 球下方 */
  @Prop selectedNode: string = '';
  /** VPN 是否已连接 */
  @Prop connected: boolean = false;

  @State private sceneReady: boolean = false;
  @State private sceneFailed: boolean = false;
  @State private styleIndex: number = 2;
  @State private materialSupported: boolean = true;
  @State private materialLevel: string = '—';
  @State private rotY: number = 0;
  @State private zoomLabel: string = '100%';

  private scene: Scene | null = null;
  private handle: Scene3DHandle | null = null;
  private flowController: HdsSceneController = new HdsSceneController();
  /** 手势起始基准，避免拖动跳动 */
  private baseRotY: number = 0;
  private baseRotX: number = 0;
  private baseZoom: number = 1;
  private sceneRequested: boolean = false;

  aboutToAppear(): void {
    try {
      this.materialSupported = uiMaterial.isImmersiveMaterialSupported();
      this.materialLevel = this.levelName(uiMaterial.getGlobalMaterialLevel());
    } catch (_err) {
      this.materialSupported = false;
      this.materialLevel = '不支持';
    }
    this.buildScene();
  }

  aboutToDisappear(): void {
    const h: Scene3DHandle | null = this.handle;
    if (h !== null) {
      Scene3D.dispose(h);
    }
    this.handle = null;
    this.scene = null;
    try {
      this.flowController.stop();
    } catch (_err) {
      // 未启动时 stop 会抛，忽略
    }
  }

  private levelName(level: uiMaterial.MaterialLevel): string {
    if (level === uiMaterial.MaterialLevel.EXQUISITE) {
      return '精致';
    }
    if (level === uiMaterial.MaterialLevel.GENTLE) {
      return '柔和';
    }
    if (level === uiMaterial.MaterialLevel.SMOOTH) {
      return '流畅';
    }
    return '未知';
  }

  private async buildScene(): Promise<void> {
    if (this.sceneRequested) {
      return;
    }
    this.sceneRequested = true;
    const h: Scene3DHandle = await Scene3D.build(1.4);
    if (!h.ready || h.scene === null) {
      this.sceneFailed = true;
      this.sceneReady = false;
      return;
    }
    this.handle = h;
    this.scene = h.scene;
    this.sceneReady = true;
    this.applyRealData();
    hilog.info(DOMAIN, TAG, '3d scene ready');
  }

  /** 把真实统计量映射到 3D 外观 */
  private applyRealData(): void {
    const h: Scene3DHandle | null = this.handle;
    if (h === null || !h.ready) {
      return;
    }
    Scene3D.applyData(h, this.downTotal + this.upTotal, this.healthState !== 'fail');
    this.zoomLabel = Math.round(h.zoom * 100) + '%';
  }

  private currentStyle(): uiMaterial.ImmersiveStyle {
    if (this.styleIndex <= 0) {
      return uiMaterial.ImmersiveStyle.ULTRA_THIN;
    }
    if (this.styleIndex === 1) {
      return uiMaterial.ImmersiveStyle.THIN;
    }
    if (this.styleIndex === 2) {
      return uiMaterial.ImmersiveStyle.REGULAR;
    }
    if (this.styleIndex === 3) {
      return uiMaterial.ImmersiveStyle.THICK;
    }
    return uiMaterial.ImmersiveStyle.ULTRA_THICK;
  }

  private buildMaterial(): uiMaterial.Material | undefined {
    if (!this.materialSupported) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: this.currentStyle(),
      colorInvert: true,
      applyShadow: true,
      interactive: true
    });
  }

  private onPan(dx: number, dy: number): void {
    const h: Scene3DHandle | null = this.handle;
    if (h === null || !h.ready) {
      return;
    }
    h.rotY = this.baseRotY + dx * 0.4;
    h.rotX = Math.max(-80, Math.min(80, this.baseRotX + dy * 0.4));
    Scene3D.applyTransform(h);
    this.rotY = Math.round(h.rotY);
  }

  private onPinch(scale: number): void {
    const h: Scene3DHandle | null = this.handle;
    if (h === null || !h.ready) {
      return;
    }
    h.zoom = Math.max(0.4, Math.min(3, this.baseZoom * scale));
    Scene3D.applyTransform(h);
    this.zoomLabel = Math.round(h.zoom * 100) + '%';
  }

  build() {
    Scroll() {
      ContentFrame() {
        Column({ space: 12 }) {
          this.capabilityHeader()
          this.sceneCard()
          this.materialCard()
          this.flowCard()
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 12, bottom: 180 })
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  private capabilityHeader() {
    Column({ space: 6 }) {
      Text('视觉与交互 3D · 沉浸光感')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text'))
      Text('设备材质档位 ' + this.materialLevel + ' · 沉浸材质'
        + (this.materialSupported ? '可用' : '不可用（已降级为普通底色）'))
        .fontSize(11)
        .fontColor($r('app.color.muted'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 3D 场景卡：Component3D 承载 Scene，手势驱动旋转/缩放 */
  @Builder
  private sceneCard() {
    Column({ space: 8 }) {
      Row() {
        Text('出口节点 3D 视图')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.sub'))
        Blank()
        Text('拖动旋转 · 双指缩放')
          .fontSize(10)
          .fontColor($r('app.color.muted'))
      }
      .width('100%')

      if (this.sceneReady && this.scene !== null) {
        Component3D({ scene: this.scene })
          .width('100%')
          .height(260)
          .backgroundColor($r('app.color.app'))
          .borderRadius(8)
          .gesture(
            GestureGroup(GestureMode.Parallel,
              PanGesture()
                .onActionStart(() => {
                  const h: Scene3DHandle | null = this.handle;
                  if (h !== null) {
                    this.baseRotY = h.rotY;
                    this.baseRotX = h.rotX;
                  }
                })
                .onActionUpdate((event: GestureEvent) => {
                  this.onPan(event.offsetX, event.offsetY);
                }),
              PinchGesture({ fingers: 2 })
                .onActionStart(() => {
                  const h: Scene3DHandle | null = this.handle;
                  if (h !== null) {
                    this.baseZoom = h.zoom;
                  }
                })
                .onActionUpdate((event: GestureEvent) => {
                  this.onPinch(event.scale);
                })
            )
          )
      } else {
        Column({ space: 4 }) {
          Text(this.sceneFailed ? '3D 渲染不可用' : '3D 场景构建中...')
            .fontSize(12)
            .fontColor($r('app.color.muted'))
          if (this.sceneFailed) {
            Text('当前设备/算力档位不支持 ArkGraphics3D，已降级')
              .fontSize(10)
              .fontColor($r('app.color.muted'))
          }
        }
        .width('100%')
        .height(260)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.app'))
        .borderRadius(8)
      }

      Row({ space: 10 }) {
        Text(this.selectedNode.length > 0 ? this.selectedNode : '未选择节点')
          .fontSize(12)
          .fontColor($r('app.color.text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('缩放 ' + this.zoomLabel)
          .fontSize(10)
          .fontColor($r('app.color.muted'))
        Text('偏航 ' + this.rotY + '°')
          .fontSize(10)
          .fontColor($r('app.color.muted'))
      }
      .width('100%')

      Text('球体大小随本次会话累计流量变化：↓ ' + Fmt.bytes(this.downTotal)
        + ' · ↑ ' + Fmt.bytes(this.upTotal)
        + (this.healthState === 'fail' ? ' · 链路异常（球体压扁告警）' : ''))
        .fontSize(10)
        .fontColor($r('app.color.muted'))
        .width('100%')
    }
    .width('100%')
    .padding(12)
    .borderRadius(10)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
  }

  /** 沉浸光感卡：systemMaterial + ImmersiveMaterial，点击循环档位 */
  @Builder
  private materialCard() {
    Column({ space: 10 }) {
      Row() {
        Text('沉浸光感材质')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.sub'))
        Blank()
        Text(this.materialSupported ? '点击切换档位' : '设备不支持')
          .fontSize(10)
          .fontColor($r('app.color.muted'))
      }
      .width('100%')

      Column({ space: 4 }) {
        Text('当前档位：' + STYLE_LABELS[this.styleIndex])
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text'))
        Text('连接状态 ' + (this.connected ? '已保护' : '未连接')
          + ' · 材质由系统按设备算力自适应渲染')
          .fontSize(10)
          .fontColor($r('app.color.sub'))
      }
      .width('100%')
      .padding(16)
      .borderRadius(12)
      .systemMaterial(this.buildMaterial())
      .backgroundColor(this.materialSupported ? Color.Transparent : $r('app.color.surface2'))
      .onClick(() => {
        if (!this.materialSupported) {
          return;
        }
        this.styleIndex = (this.styleIndex + 1) % STYLE_LABELS.length;
      })
    }
    .width('100%')
    .padding(12)
    .borderRadius(10)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
  }

  /** HDS 双边流光（UIDesignKit） */
  @Builder
  private flowCard() {
    Column({ space: 10 }) {
      Row() {
        Text('HDS 双边流光')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.sub'))
        Blank()
        Text('播放')
          .fontSize(10)
          .fontColor($r('app.color.blue'))
          .onClick(() => {
            this.startFlow();
          })
      }
      .width('100%')

      HdsVisualComponent()
        .width('100%')
        .height(96)
        .borderRadius(10)
        .scene(HdsSceneType.DUAL_EDGE_FLOW_LIGHT_WITH_BACKGROUND_MASK, this.flowController)
    }
    .width('100%')
    .padding(12)
    .borderRadius(10)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
  }

  private startFlow(): void {
    const first: hdsEffect.EdgeFlowLightParam = {
      startPos: 0,
      endPos: 0.5,
      color: $r('app.color.green')
    };
    const second: hdsEffect.EdgeFlowLightParam = {
      startPos: 0.5,
      endPos: 1,
      color: $r('app.color.blue')
    };
    try {
      this.flowController
        .setSceneParams({
          backgroundMaskColors: [$r('app.color.app'), $r('app.color.surface2')],
          firstEdgeFlowLight: first,
          secondEdgeFlowLight: second
        })
        .start();
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'unknown';
      hilog.warn(DOMAIN, TAG, 'flow light start failed: %{public}s', msg);
    }
  }
}
