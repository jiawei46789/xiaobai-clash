/**
 * 3D 场景构建（视觉与交互 3D）。
 *
 * 用 ArkGraphics3D 的 Scene + 内置几何体（SphereGeometry）搭一个可交互的
 * 「流量星球」：球体代表当前出口节点，拖动旋转、双指缩放，数据变化时改变
 * 球体大小与颜色。全部走系统 3D 渲染管线（Component3D 承载），不自绘。
 *
 * 设计约束（与本工程一致）：所有数值都来自真实运行统计，不做模拟。
 * 球体半径/颜色由外部传入的真实量（累计流量、链路健康度）驱动。
 */
import {
  Scene,
  Node,
  Geometry,
  Light,
  Camera,
  LightType,
  MaterialType,
  SphereGeometry,
  MeshResource,
  Material
} from '@kit.ArkGraphics3D';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x2030;
const TAG = 'Scene3D';

/** 场景构建结果句柄：页面持有它来做交互（旋转/缩放/改数据） */
export class Scene3DHandle {
  scene: Scene | null = null;
  /** 承载球体的几何节点（旋转/缩放作用在它身上） */
  geo: Geometry | null = null;
  camera: Camera | null = null;
  light: Light | null = null;
  ready: boolean = false;

  /** 累计旋转（度），供手势增量叠加 */
  rotY: number = 0;
  rotX: number = 0;
  /** 当前缩放倍率 */
  zoom: number = 1;
}

export class Scene3D {
  /**
   * 构建场景。失败时返回 ready=false 的句柄（页面据此降级为纯 2D 展示），
   * 不抛异常 —— 3D 在某些设备/算力档位上可能不可用，不该影响主功能。
   */
  static async build(radius: number): Promise<Scene3DHandle> {
    const handle = new Scene3DHandle();
    try {
      // 空场景：不加载外部 glTF 资源，全部用内置几何体现场创建
      const scene: Scene = await Scene.load();
      handle.scene = scene;
      const factory = scene.getResourceFactory();

      // 1) 球体网格 + 材质 + 几何节点
      const sphere: SphereGeometry = new SphereGeometry();
      sphere.radius = radius;
      sphere.segmentCount = 32;
      const mesh: MeshResource = await factory.createMesh({ name: 'mesh' }, sphere);
      const material: Material =
        await factory.createMaterial({ name: 'mat' }, MaterialType.METALLIC_ROUGHNESS);
      const geo: Geometry = await factory.createGeometry({ name: 'geo' }, mesh);
      scene.importNode('geo', geo, scene.root);
      handle.geo = geo;
      // 材质挂到网格上（materialOverride 覆盖子网格默认材质）
      try {
        geo.mesh.materialOverride = material;
      } catch (_err) {
        hilog.warn(DOMAIN, TAG, 'materialOverride unsupported, keep default');
      }

      // 2) 方向光：没有光照金属材质会是纯黑
      const light: Light = await factory.createLight({ name: 'light' }, LightType.DIRECTIONAL);
      light.intensity = 80000;
      light.enabled = true;
      light.position = { x: 4, y: 6, z: 6 };
      scene.importNode('light', light, scene.root);
      handle.light = light;

      // 3) 相机：看向原点，留出球的完整视锥
      const camera: Camera = await factory.createCamera({ name: 'camera' });
      camera.fov = Math.PI / 4;
      camera.nearPlane = 0.1;
      camera.farPlane = 100;
      camera.position = { x: 0, y: 0, z: 6 };
      scene.importNode('camera', camera, scene.root);
      handle.camera = camera;

      scene.renderFrame();
      handle.ready = true;
      hilog.info(DOMAIN, TAG, 'scene built radius=%{public}s', radius.toFixed(2));
    } catch (err) {
      handle.ready = false;
      const msg = err instanceof Error ? err.message : 'unknown';
      hilog.error(DOMAIN, TAG, 'scene build failed: %{public}s', msg);
    }
    return handle;
  }

  /**
   * 应用交互变换：拖动旋转 + 双指缩放。
   * 四元数用欧拉角（绕 Y 再绕 X）合成，避免万向节之外的复杂数学。
   */
  static applyTransform(handle: Scene3DHandle): void {
    if (!handle.ready || handle.geo === null || handle.scene === null) {
      return;
    }
    const geo: Geometry = handle.geo;
    const rx = Scene3D.deg2rad(handle.rotX);
    const ry = Scene3D.deg2rad(handle.rotY);
    // q = qy * qx
    const cy = Math.cos(ry / 2);
    const sy = Math.sin(ry / 2);
    const cx = Math.cos(rx / 2);
    const sx = Math.sin(rx / 2);
    geo.rotation = {
      x: cy * sx,
      y: sy * cx,
      z: -sy * sx,
      w: cy * cx
    };
    const s = handle.zoom;
    geo.scale = { x: s, y: s, z: s };
    handle.scene.renderFrame();
  }

  /**
   * 用真实数据驱动外观：累计流量越大球越大，链路异常时压扁（视觉告警）。
   * bytes 传 -1 表示未知，此时只按健康度调整。
   */
  static applyData(handle: Scene3DHandle, bytes: number, healthy: boolean): void {
    if (!handle.ready || handle.geo === null || handle.scene === null) {
      return;
    }
    let factor: number = 1;
    if (bytes > 0) {
      // 每 1 GB 放大 4%，封顶 1.6 倍，避免球体撑出视锥
      const gb = bytes / (1024 * 1024 * 1024);
      factor = Math.min(1.6, 1 + gb * 0.04);
    }
    if (!healthy) {
      factor *= 0.82;
    }
    handle.zoom = factor;
    Scene3D.applyTransform(handle);
  }

  /** 释放场景资源（页面卸载时调用，避免显存泄漏） */
  static dispose(handle: Scene3DHandle): void {
    if (handle.scene !== null) {
      try {
        handle.scene.destroy();
      } catch (_err) {
        // 已销毁时重复调用会抛，忽略
      }
    }
    handle.scene = null;
    handle.geo = null;
    handle.camera = null;
    handle.light = null;
    handle.ready = false;
  }

  private static deg2rad(d: number): number {
    return d * Math.PI / 180;
  }
}
