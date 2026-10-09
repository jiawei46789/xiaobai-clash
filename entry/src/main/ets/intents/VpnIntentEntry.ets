/**
 * 小艺智能体接入（InsightIntent / IntentsKit）。
 *
 * 把「连接 / 断开 VPN」定义成**意图**，注册给系统 AI 入口（小艺问答 /
 * 智能搜索 / 智能推荐）。用户对小艺说「帮我连上加速」时，系统按
 * executeMode=UI_ABILITY_FOREGROUND 拉起 EntryAbility 并调用 onExecute()。
 *
 * 关键约束（来自 @ohos.app.ability.InsightIntentDecorator 声明，编译期强校验）：
 *  - @InsightIntentEntry 修饰的类必须 `export default`
 *  - 类属性只能是基础类型或意图实体 —— 所以入参用 `action: string`
 *  - parameters/result 里声明的字段必须与类属性同名同类型
 *  - 返回值是 IntentResult<意图实体>，实体必须实现 insightIntent.IntentEntity
 *    （即带 entityId）
 *
 * 为什么不在这里直接开 VPN：意图执行器与主界面不在同一 UI 上下文，且本工程
 * 自 1.6.2 起「VPN 只允许手动开关」是硬约束。所以执行器只负责**把动作意图
 * 交给主界面**（AppStorage 单值信箱 + 拉起 UIAbility），由 Index 读取后走既有
 * toggleVpn() 链路 —— 保持开关只有一个事实来源，避免出现第二条能悄悄开
 * VPN 的路径。
 */
import {
  InsightIntentEntryExecutor,
  InsightIntentEntry,
  InsightIntentEntity,
  insightIntent
} from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x2031;
const TAG = 'VpnIntent';

/** AppStorage 信箱键：执行器写入，Index 页读取后清空 */
export const INTENT_VPN_ACTION_KEY = 'intentVpnAction';

/** 意图返回体：字段只放基础类型（装饰器编译期按 result schema 校验） */
@InsightIntentEntity({ entityCategory: 'VpnControlResult' })
export class VpnIntentResult implements insightIntent.IntentEntity {
  /** IntentEntity 要求的实体 ID */
  entityId: string = 'vpn-control';
  /** 是否受理（true = 已把动作转交主界面执行） */
  accepted: boolean = false;
  /** 面向用户的一句话说明，会显示在小艺侧 */
  message: string = '';
}

/**
 * 连接/断开 VPN 的意图执行器。
 *
 * `action` 属性与 parameters.action 一一对应；名字或类型不符会直接编译失败，
 * 这是有意的强约束，避免意图定义与实际处理逻辑漂移。
 */
@InsightIntentEntry({
  intentName: 'ControlVpn',
  domain: 'ToolsDomain',
  intentVersion: '1.0.0',
  displayName: '连接或断开加速',
  displayDescription: '按指令打开或关闭本应用的 VPN 加速通道',
  abilityName: 'EntryAbility',
  executeMode: [insightIntent.ExecuteMode.UI_ABILITY_FOREGROUND],
  llmDescription: '当用户想开启、连接、启动，或关闭、断开、停止 VPN 加速/代理时调用',
  keywords: ['连接加速', '断开加速', '开启VPN', '关闭VPN', '加速', '代理'],
  parameters: {
    type: 'object',
    properties: {
      action: {
        type: 'string',
        description: '要执行的动作：connect 表示连接，disconnect 表示断开'
      }
    },
    required: ['action']
  },
  result: {
    type: 'object',
    properties: {
      accepted: { type: 'boolean', description: '是否受理该动作' },
      message: { type: 'string', description: '面向用户的说明' }
    }
  }
})
export default class VpnIntentEntry extends InsightIntentEntryExecutor<VpnIntentResult> {
  /** 意图入参，与 parameters.action 同名同类型 */
  action: string = '';

  async onExecute(): Promise<insightIntent.IntentResult<VpnIntentResult>> {
    const want: string = (this.action ?? '').toLowerCase();
    hilog.info(DOMAIN, TAG, 'intent execute action=%{public}s mode=%{public}d',
      want, this.executeMode);

    const result = new VpnIntentResult();
    if (want === 'connect' || want === 'on' || want === 'start') {
      this.publish('connect');
      result.accepted = true;
      result.message = '已打开加速连接页面';
    } else if (want === 'disconnect' || want === 'off' || want === 'stop') {
      this.publish('disconnect');
      result.accepted = true;
      result.message = '已打开断开加速的操作入口';
    } else {
      result.accepted = false;
      result.message = '未能识别的动作，请在应用内手动操作';
    }
    return { code: 0, result: result };
  }

  /**
   * 把动作投递给主界面。
   *
   * 失败也不影响意图返回「已受理」：UIAbility 已被拉到前台，用户能直接手动
   * 操作，比把错误抛回小艺更有用。
   */
  private publish(action: string): void {
    try {
      AppStorage.setOrCreate(INTENT_VPN_ACTION_KEY, action);
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'unknown';
      hilog.warn(DOMAIN, TAG, 'publish action failed: %{public}s', msg);
    }
  }
}
