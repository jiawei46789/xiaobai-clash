export interface ProxyNode {
  name: string;
  protocol: string;
  group: string;
  latency: number;
  selected: boolean;
  link?: string;
}

export interface ProxyGroup {
  name: string;
  type: string;
  nodes: ProxyNode[];
}

export interface AppConnection {
  id: string;
  host: string;
  app: string;
  rule: string;
  proxy: string;
  down: string;
  up: string;
  time: string;
}

export interface RuleItem {
  type: string;
  payload: string;
  proxy: string;
}

export interface RecoveryEvent {
  time: string;
  title: string;
  desc: string;
  type: string;
}

export interface DnsServer {
  name: string;
  address: string;
  latency: string;
  kind: string;
}

/**
 * 订阅流量用量（仅真实数据，来源：订阅响应的 `subscription-userinfo` 响应头）。
 * 主体机场客户端都走这个约定：格式形如
 *   upload=123; download=456; total=789; expire=1730000000
 * 其中 expire 为到期时间（秒时间戳）。字段可能缺失，缺失时按 -1/0 表示未知。
 */
export interface SubscriptionUsage {
  /** 已上传字节 */
  upload: number;
  /** 已下载字节 */
  download: number;
  /** 套餐总流量字节；-1 表示订阅方未提供 */
  total: number;
  /** 已用 = upload + download */
  used: number;
  /** 剩余字节；total 未知时为 -1 */
  remaining: number;
  /** 到期时间（毫秒时间戳）；0 表示未提供 */
  expireMs: number;
  /** 最近一次刷新用量的时间（毫秒时间戳） */
  updatedAt: number;
}

export interface SubscriptionProfile {
  id: string;
  name: string;
  sourceUrl: string;
  detectedFormat: string;
  nodeCount: number;
  updatedAt: string;
  active: boolean;
  content: string;
  /** 最近一次解析到的流量用量；null = 该订阅未提供（旧存档兼容） */
  usage?: SubscriptionUsage | null;
}

export interface ImportResult {
  ok: boolean;
  message: string;
  format: string;
  nodeCount: number;
  nodes: ProxyNode[];
  content: string;
}

export interface GeneratedConfig {
  path: string;
  controllerUrl: string;
  mixedPort: number;
  timestamp: string;
}

export interface AppSettings {
  autoConnect: boolean;
  networkRecover: boolean;
  screenKeep: boolean;
  failClosed: boolean;
  notificationOn: boolean;
  dnsMode: string;
  proxyMode: string;
  logLevel: string;
  testUrl: string;
  /** 分应用代理：关闭时不启用；黑名单语义见 PROXY_EXCLUDED_APPS */
  perAppProxyEnabled: boolean;
  /** 深色模式：true 强制深色配色，false 强制浅色（资源限定词 base/dark 切换） */
  darkMode: boolean;
  /** 定时更新订阅：间隔分钟数（0=关闭，有效范围 1-10080）。
   * 应用存活期间到点自动刷新当前订阅；回前台/启动时补检一次 */
  subUpdateMinutes: number;
  /** 自动选最优节点：开=当前节点约 30 秒不可用时自动切到最快可用节点；关=只做手动选择 */
  nodeAutoSwitch: boolean;
}

/**
 * 分应用代理的开关状态。
 * 语义与 FlClash 一致：**关 = 不使用代理（直连），开 = 使用代理**。
 * 因此「黑名单」= 那些被关掉的包名集合，持久化时只存被关掉的。
 */
export interface AppProxyRule {
  bundleName: string;
  appName: string;
  /** true = 走代理；false = 直连（不使用代理） */
  proxied: boolean;
}

export type VpnState = 'idle' | 'connecting' | 'connected' | 'stopping' | 'error';
