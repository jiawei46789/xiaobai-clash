import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import fileIo from '@ohos.file.fs';
import { http, connection } from '@kit.NetworkKit';
import { buffer, util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ImportResult, ProxyNode, SubscriptionProfile, SubscriptionUsage } from '../models/ArkModels';

const DOMAIN = 0x2023;
const TAG = 'SubSvc';

const STORE_NAME = 'lian_subscriptions';
const KEY_PROFILES = 'subscription.profiles';
const KEY_ACTIVE_ID = 'subscription.activeId';
const SUB_DIR = '/subscriptions';
const UA = 'lian-connect/0.01';
const ACCEPT = 'application/x-yaml, text/yaml, text/plain';

/**
 * mihomo 内核的本地混合代理端口（与 ConfigService 的 LOCAL_MIXED_PORT 一致）。
 *
 * 为什么需要它：很多机场订阅域名在 Cloudflare 后面，从大陆直连会在 TLS
 * 握手阶段就被 SNI 重置（实机报 2300999 Internal error，PC 侧 schannel
 * 同样握手失败），根本拿不到 HTTP 状态码。而内核起来后本地 7890 是一个
 * 可用的 HTTP 代理入口，走它就能绕过直连被重置的问题。
 *
 * 注意：这要求加速已连接（内核在跑）。未连接时连不上 7890，会快速失败
 * 并给出「先连接加速再导入」的可操作提示，而不是无限重试。
 */
const LOCAL_PROXY_HOST = '127.0.0.1';
const LOCAL_PROXY_PORT = 7890;

/**
 * UA 回退链（修复导入报 HTTP 403）。
 *
 * 很多机场面板/CDN WAF 会对“未知客户端”直接回 403/406，却放行常见
 * Clash/小火箭 客户端的 UA。不同面板放行名单不一样（有的只认 clash，
 * 有的反过来拒绝 clash），所以这里把常见 UA 排成一队依次试，
 * 第一个拿到 2xx 的就用它。默认 UA 放第一位（不改变已有行为）。
 */
const UA_CHAIN: string[] = [
  UA,
  'clash-verge/v1.5.11',
  'ClashforWindows/0.20.39',
  'clash.meta',
  'mihomo/1.18.10',
  'ClashMetaForAndroid/2.11.4',
  'Clash/1.18.0',
  'v2rayN/6.45',
  'Shadowrocket/2537',
  'Mozilla/5.0 (Linux; Android 14; Mobile)'
];

/** 一次原始 HTTP 响应的中间表示 */
interface RawResponse {
  status: number;
  content: string;
  header: Object;
}

/**
 * 一轮抓取尝试（直连 或 本地代理）的结果。
 *
 * content 非 null 即成功。失败时 status/code/message 保留最后一次的可诊断信息：
 * status>0 表示拿到了 HTTP 响应（链路通、服务器拒绝），code>0 表示网络层异常，
 * proxyReachable 用来区分「内核没跑」与「内核跑了但上游也失败」——两者的
 * 用户处置方式完全不同，必须分开报。
 */
interface AttemptResult {
  content: string | null;
  usage: SubscriptionUsage | null;
  status: number;
  code: number;
  message: string;
  proxyTried: boolean;
  proxyReachable: boolean;
}

/**
 * 把任意抛出值转成可读文本。
 *
 * 必须单独处理：HarmonyOS 网络栈抛的是 `BusinessError`，它**不是**
 * `Error` 的实例，`instanceof Error` 为 false，而 `String(err)` 会得到
 * `[object Object]` —— 真正的错误码（例如 2300006 无法解析主机）就丢了，
 * 界面上只剩一句无法排查的废话。这里按鸭子类型取 code/message。
 */
function describeError(err: Object): string {
  if (err instanceof Error) {
    return err.message;
  }
  let code: number = 0;
  let msg: string = '';
  try {
    const e = err as Record<string, Object>;
    const c = e['code'];
    if (typeof c === 'number') {
      code = c;
    }
    const m = e['message'];
    if (typeof m === 'string') {
      msg = m;
    }
  } catch (_err) {
    return String(err);
  }
  if (code !== 0 && msg.length > 0) {
    return code + ' ' + msg;
  }
  if (code !== 0) {
    return '错误码 ' + code;
  }
  if (msg.length > 0) {
    return msg;
  }
  return String(err);
}

/** 网络栈错误码 → 人话。覆盖最常见的几类，其余原样带上码值 */
function networkHint(code: number): string {
  if (code === 2300999) {
    return 'TLS/连接层失败：该域名很可能被 SNI 重置，需在加速已连接后重试';
  }
  if (code === 2300006) {
    return '无法解析主机名（DNS 失败，检查链接或网络）';
  }
  if (code === 2300007) {
    return '无法连接到服务器（主机不可达或端口不通）';
  }
  if (code === 2300028) {
    return '请求超时';
  }
  if (code === 2300035) {
    return 'SSL/TLS 握手失败（证书或加密套件不被接受）';
  }
  if (code === 2300060 || code === 2300056) {
    return '连接被对端重置';
  }
  return '';
}

/**
 * 与 UA 无关、换 UA 也不会好的网络层错误码。
 *
 * 这类错误（SNI 重置、DNS 失败、TLS 握手失败）属于链路问题，重试 10 个 UA
 * 只会把一次失败放大成十次。命中时应立刻停下并走本地代理兜底。
 */
function isNetworkLevel(code: number): boolean {
  return code === 2300999 || code === 2300006 || code === 2300007
    || code === 2300028 || code === 2300035 || code === 2300056 || code === 2300060;
}

/**
 * 一次订阅抓取的完整结果。
 *
 * 除了配置正文（content），还带有从响应头 `subscription-userinfo` 解析出的
 * 流量用量（usage）。许多机场只在**响应头**里给用量，正文里看不到，所以必须
 * 在下载这一层就把头抓下来，不能等以后再单独发一次请求（会希望重定向/鉴权
 * 变得复杂）。usage 为 null 表示该订阅方未提供用量信息。
 */
interface FetchResult {
  content: string;
  usage: SubscriptionUsage | null;
}

/**
 * Clash YAML 顶层键表（顶格匹配）：命中任意一个即认定为 YAML。
 * 真实订阅经常以 `# 注释`、`allow-lan:`、`mode:`、`proxy-providers:` 等开头，
 * 旧版只认 6 个前缀会把大量合法 Clash 订阅拒为「不支持」。
 */
const CLASH_YAML_KEYS: string[] = [
  'proxies:', 'proxy-groups:', 'proxy-providers:', 'rules:', 'rule-providers:',
  'mixed-port:', 'port:', 'socks-port:', 'redir-port:', 'tproxy-port:',
  'allow-lan:', 'bind-address:', 'mode:', 'log-level:', 'dns:', 'tun:',
  'profile:', 'external-controller:', 'external-ui:', 'geodata-mode:',
  'geox-url:', 'experimental:', 'authentication:', 'hosts:', 'interface:',
  'routing-mark:', 'ipv6:', 'unified-delay:', 'tcp-concurrent:'
];

export class SubscriptionService {
  private store: preferences.Preferences;
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
  }

  loadProfiles(): SubscriptionProfile[] {
    let raw = '[]';
    let activeId = '';
    try {
      raw = this.store.getSync(KEY_PROFILES, '[]') as string;
      activeId = this.store.getSync(KEY_ACTIVE_ID, '') as string;
    } catch (_err) {
      return [];
    }
    let profiles: SubscriptionProfile[] = [];
    try {
      const parsed = JSON.parse(raw) as Object;
      if (Array.isArray(parsed)) {
        profiles = parsed as SubscriptionProfile[];
      }
    } catch (_err) {
      profiles = [];
    }
    profiles = profiles.filter((profile) => this.isValidProfile(profile));
    for (let i = 0; i < profiles.length; i++) {
      profiles[i].active = profiles[i].id === activeId;
    }
    return profiles;
  }

  getActive(): SubscriptionProfile | null {
    const profiles = this.loadProfiles();
    for (let i = 0; i < profiles.length; i++) {
      if (profiles[i].active) {
        return profiles[i];
      }
    }
    if (profiles.length > 0) {
      profiles[0].active = true;
      this.saveProfiles(profiles);
      return profiles[0];
    }
    return null;
  }

  async addSubscription(url: string, name: string): Promise<SubscriptionProfile> {
    const validUrl = this.validateUrl(url);
    const fetched = await this.fetchSubscription(validUrl);
    const result = this.analyzeContent(fetched.content);
    if (!result.ok) {
      throw new Error(result.message);
    }
    return this.persistProfile(name.length > 0 ? name : '我的订阅', validUrl, result, fetched.usage);
  }

  addPastedContent(name: string, content: string): SubscriptionProfile {
    const result = this.analyzeContent(content);
    if (!result.ok) {
      throw new Error(result.message);
    }
    // 剪切板导入没有响应头，只能尝试从正文注释里提取用量（无则为 null）
    const usage = this.usageFromBody(content);
    return this.persistProfile(name.length > 0 ? name : '剪贴板配置', 'pasted://local', result, usage);
  }

  /**
   * 重新下载指定订阅并原地更新（保留 id 与激活状态，不产生重复订阅）。
   */
  async refreshSubscription(id: string): Promise<SubscriptionProfile> {
    const profiles = this.loadProfiles();
    let target: SubscriptionProfile | undefined = undefined;
    for (let i = 0; i < profiles.length; i++) {
      if (profiles[i].id === id) {
        target = profiles[i];
        break;
      }
    }
    if (target === undefined) {
      throw new Error('订阅不存在');
    }
    if (target.sourceUrl.indexOf('pasted://') === 0) {
      throw new Error('本地粘贴的配置无法刷新，请重新导入');
    }
    const validUrl = this.validateUrl(target.sourceUrl);
    const fetched = await this.fetchSubscription(validUrl);
    const result = this.analyzeContent(fetched.content);
    if (!result.ok) {
      throw new Error(result.message);
    }
    this.writeContent(id, result.content);
    // 用量优先用本次响应头；本次未提供时保留上一次已知值，避免刷新一下反而把用量“洗掉”
    let usage: SubscriptionUsage | null = fetched.usage;
    if (usage === null && target.usage !== undefined && target.usage !== null) {
      usage = target.usage;
    }
    const updated: SubscriptionProfile = {
      id: target.id,
      name: target.name,
      sourceUrl: target.sourceUrl,
      detectedFormat: result.format,
      nodeCount: result.nodeCount,
      updatedAt: new Date().toISOString(),
      active: target.active,
      content: '',
      usage: usage
    };
    const next: SubscriptionProfile[] = [];
    for (let i = 0; i < profiles.length; i++) {
      next.push(profiles[i].id === id ? updated : profiles[i]);
    }
    this.saveProfiles(next);
    return updated;
  }

  selectSubscription(id: string): void {
    const profiles = this.loadProfiles();
    let found = false;
    for (let i = 0; i < profiles.length; i++) {
      profiles[i].active = profiles[i].id === id;
      if (profiles[i].active) {
        found = true;
      }
    }
    if (!found) {
      throw new Error('Subscription not found');
    }
    this.saveProfiles(profiles);
  }

  deleteSubscription(id: string): void {
    let profiles = this.loadProfiles();
    profiles = profiles.filter((profile) => profile.id !== id);
    if (profiles.length > 0) {
      profiles[0].active = true;
    }
    this.deleteContent(id);
    this.saveProfiles(profiles);
  }

  loadContent(id: string): string {
    const path = this.contentPath(id);
    try {
      return fileIo.readTextSync(path);
    } catch (_err) {
      return '';
    }
  }

  analyzeContent(content: string): ImportResult {
    let format: string = this.detectFormat(content);
    let effective: string = content;
    if (format === 'base64-yaml') {
      // base64 包裹的 Clash YAML：解码后按普通 clash-yaml 处理（落盘存 YAML 本体，
      // ConfigService 才能直接解析）
      effective = this.tryDecodeBase64(content.trim()).trim();
      format = 'clash-yaml';
    }
    if (format === 'unsupported') {
      return {
        ok: false,
        message: '不支持的配置格式：请使用 Clash/Mihomo YAML、Base64（链接或 YAML）或分享链接',
        format: format,
        nodeCount: 0,
        nodes: [],
        content: content
      };
    }
    const nodes = this.parseNodes(effective, format);
    if (nodes.length === 0) {
      // 纯 proxy-providers 订阅：节点由核心在运行期拉取，这里按 provider 条目数计入
      const providers: number = format === 'clash-yaml' ? this.countProxyProviders(effective) : 0;
      if (providers === 0) {
        return {
          ok: false,
          message: '配置中未解析到可用节点',
          format: format,
          nodeCount: 0,
          nodes: [],
          content: effective
        };
      }
      return {
        ok: true,
        message: this.formatLabel(format) + ' · ' + providers + ' 个节点源',
        format: format,
        nodeCount: providers,
        nodes: [],
        content: effective
      };
    }
    return {
      ok: true,
      message: this.formatLabel(format),
      format: format,
      nodeCount: nodes.length,
      nodes: nodes,
      content: effective
    };
  }

  private persistProfile(name: string, sourceUrl: string, result: ImportResult,
    usage: SubscriptionUsage | null): SubscriptionProfile {
    const id = this.newId();
    const profile: SubscriptionProfile = {
      id: id,
      name: name,
      sourceUrl: sourceUrl,
      detectedFormat: result.format,
      nodeCount: result.nodeCount,
      updatedAt: new Date().toISOString(),
      active: true,
      content: '',
      usage: usage
    };
    this.writeContent(id, result.content);
    let profiles = this.loadProfiles();
    for (let i = 0; i < profiles.length; i++) {
      profiles[i].active = false;
    }
    profiles.push(profile);
    this.saveProfiles(profiles);
    return profile;
  }

  private validateUrl(url: string): string {
    const trimmed = url.trim();
    if (trimmed.length === 0) {
      throw new Error('订阅链接不能为空');
    }
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      throw new Error('订阅链接必须以 http:// 或 https:// 开头');
    }
    return trimmed;
  }

  /**
   * 下载订阅：先直连，失败则走内核本地代理兜底。
   *
   * 两轮（direct → local proxy），每轮内部依次试 UA_CHAIN：
   *  - 拿到 2xx 立即返回；
   *  - 网络层错误（SNI 重置/DNS/TLS/超时）与 UA 无关，立刻结束本轮，
   *    换下一轮链路 —— 绝不能拿 10 个 UA 各等 30 秒，导入会卡死几分钟；
   *  - HTTP 403/406/451/5xx 才继续试下一个 UA（这类才是 WAF 挑客户端）。
   *
   * 为什么要第二轮：机场域名多在 Cloudflare 后，大陆直连会在握手阶段被 SNI
   * 重置（实机 2300999），此时唯一可行路径是走已连接的加速隧道。
   */
  private async fetchSubscription(url: string): Promise<FetchResult> {
    const direct: AttemptResult = await this.attempt(url, false);
    if (direct.usage !== null || direct.content !== null) {
      return { content: direct.content ?? '', usage: direct.usage };
    }
    // 直连没成：走本地代理再试一轮（需要加速已连接）
    const viaProxy: AttemptResult = await this.attempt(url, true);
    if (viaProxy.content !== null) {
      return { content: viaProxy.content, usage: viaProxy.usage };
    }
    throw new Error(this.buildFetchError(direct, viaProxy));
  }

  /** 单轮尝试的结果：content 非 null 即成功；否则带出状态码/错误码供诊断 */
  private async attempt(url: string, useProxy: boolean): Promise<AttemptResult> {
    const out: AttemptResult = {
      content: null,
      usage: null,
      status: 0,
      code: 0,
      message: '',
      proxyTried: useProxy,
      proxyReachable: false
    };
    for (let i = 0; i < UA_CHAIN.length; i++) {
      const ua = UA_CHAIN[i];
      let resp: RawResponse | undefined = undefined;
      try {
        resp = await this.requestOnce(url, ua, useProxy);
      } catch (err) {
        out.code = this.codeOf(err);
        out.message = describeError(err);
        hilog.warn(DOMAIN, TAG, 'fetch error proxy=%{public}s: %{public}s',
          useProxy ? 'yes' : 'no', out.message);
        // 网络层错误换 UA 无意义，立即结束本轮
        if (isNetworkLevel(out.code)) {
          break;
        }
        continue;
      }
      // 能拿到 HTTP 状态码说明链路是通的（代理轮据此判断内核是否在跑）
      out.proxyReachable = true;
      const status = resp.status;
      out.status = status;
      if (status >= 200 && status < 300) {
        let usage: SubscriptionUsage | null = this.usageFromHeaders(resp.header);
        if (usage === null) {
          usage = this.usageFromBody(resp.content);
        }
        if (i > 0) {
          hilog.info(DOMAIN, TAG, 'fetch ok via UA fallback #%{public}d proxy=%{public}s',
            i, useProxy ? 'yes' : 'no');
        }
        out.content = resp.content;
        out.usage = usage;
        return out;
      }
      hilog.warn(DOMAIN, TAG, 'fetch HTTP %{public}d UA #%{public}d proxy=%{public}s',
        status, i, useProxy ? 'yes' : 'no');
      // 只有“服务器在挑客户端”的状态码值得换 UA 重试
      const retryable = status === 403 || status === 406 || status === 451 || status >= 500;
      if (!retryable) {
        break;
      }
    }
    return out;
  }

  /** 把两轮尝试的结果拼成一句可操作的错误文案 */
  private buildFetchError(direct: AttemptResult, viaProxy: AttemptResult): string {
    // 服务器明确拒绝：优先报 HTTP 状态（这才是用户看到的 403 场景）
    const status: number = viaProxy.status !== 0 ? viaProxy.status : direct.status;
    if (status === 403) {
      return 'HTTP 403：订阅链接被服务器拒绝。常见原因是订阅已到期/被重置，'
        + '或机场限制了当前出口 IP。请到机场后台重新复制订阅链接后再导入。';
    }
    if (status === 401) {
      return 'HTTP 401：订阅链接鉴权失败（token 无效或已过期），请重新复制订阅链接';
    }
    if (status === 404) {
      return 'HTTP 404：订阅地址不存在，请核对链接';
    }
    if (status > 0) {
      return '订阅返回 HTTP ' + status;
    }
    // 两轮都是网络层失败
    const code: number = direct.code !== 0 ? direct.code : viaProxy.code;
    const hint: string = code !== 0 ? networkHint(code) : '';
    if (!viaProxy.proxyReachable) {
      // 本地 7890 连不上 = 内核没跑 = 加速未连接
      return '订阅下载失败：直连被重置且本地加速未运行。请先在首页点 VPN 连接加速，'
        + '再回来导入订阅' + (hint.length > 0 ? '（直连：' + hint + '）' : '');
    }
    const detail: string = direct.message.length > 0 ? direct.message : '请检查网络和链接';
    return '订阅下载失败：' + detail + (hint.length > 0 ? '（' + hint + '）' : '');
  }

  /** 从任意抛出值里取数字错误码，取不到返回 0 */
  private codeOf(err: Object): number {
    try {
      const e = err as Record<string, Object>;
      const c = e['code'];
      if (typeof c === 'number') {
        return c;
      }
    } catch (_err) {
      return 0;
    }
    return 0;
  }

  /**
   * 单次请求（独立 http 实例，用完即销）。
   *
   * useProxy=true 时显式指定走内核本地混合端口。这里用「显式代理」而不是
   * 依赖 TUN 透明接管，原因有两个：一是导入订阅时用户往往还没连上加速，
   * 显式代理能在内核已起但 TUN 未接管本进程时仍然可用；二是路径确定，
   * 不受分应用代理黑名单影响，排查时行为可预测。
   */
  private async requestOnce(url: string, ua: string, useProxy: boolean): Promise<RawResponse> {
    const req = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 30000,
        connectTimeout: 10000,
        header: {
          'User-Agent': ua,
          'Accept': ACCEPT
        }
      };
      if (useProxy) {
        const proxy: connection.HttpProxy = {
          host: LOCAL_PROXY_HOST,
          port: LOCAL_PROXY_PORT,
          exclusionList: []
        };
        options.usingProxy = proxy;
      }
      const response = await req.request(url, options);
      return {
        status: response.responseCode,
        content: response.result as string,
        header: response.header
      };
    } finally {
      req.destroy();
    }
  }

  /**
   * 仅刷新指定订阅的流量用量（读取响应头，不改动节点正文与更新时刻）。
   *
   * 给「自动刷新用量」这个轻量路径使用：定时刷新订阅内容会重载核心造成闪断，
   * 而用量只是个展示数字，没必要动核心。pasted:// 本地导入没有远程头，
   * 直接回退到已存值。
   */
  async refreshUsage(id: string): Promise<SubscriptionUsage | null> {
    const profiles = this.loadProfiles();
    let target: SubscriptionProfile | undefined = undefined;
    for (let i = 0; i < profiles.length; i++) {
      if (profiles[i].id === id) {
        target = profiles[i];
        break;
      }
    }
    if (target === undefined) {
      throw new Error('订阅不存在');
    }
    if (target.sourceUrl.indexOf('pasted://') === 0) {
      return target.usage ?? null;
    }
    const validUrl = this.validateUrl(target.sourceUrl);
    const fetched = await this.fetchSubscription(validUrl);
    target.usage = fetched.usage;
    const next: SubscriptionProfile[] = [];
    for (let i = 0; i < profiles.length; i++) {
      next.push(profiles[i].id === id ? target : profiles[i]);
    }
    this.saveProfiles(next);
    return fetched.usage;
  }

  /** 从响应头中提取 subscription-userinfo（键名大小写不敏感） */
  private usageFromHeaders(header: Object): SubscriptionUsage | null {
    try {
      const headers = header as Record<string, string>;
      const keys: string[] = Object.keys(headers);
      for (let i = 0; i < keys.length; i++) {
        if (keys[i].toLowerCase() !== 'subscription-userinfo') {
          continue;
        }
        const raw = headers[keys[i]];
        if (typeof raw === 'string' && raw.length > 0) {
          const parsed = this.parseUsageString(raw);
          if (parsed !== null) {
            return parsed;
          }
        }
      }
    } catch (_err) {
      return null;
    }
    return null;
  }

  /** 从正文前若干行里找 `# subscription-userinfo:` 注释（少数机场的写法） */
  private usageFromBody(content: string): SubscriptionUsage | null {
    const lines: string[] = content.split('\n');
    const limit: number = Math.min(lines.length, 60);
    for (let i = 0; i < limit; i++) {
      let line: string = lines[i].trim();
      if (line.startsWith('#')) {
        line = line.substring(1).trim();
      }
      if (!line.toLowerCase().startsWith('subscription-userinfo')) {
        continue;
      }
      const colon: number = line.indexOf(':');
      if (colon > 0) {
        const parsed = this.parseUsageString(line.substring(colon + 1).trim());
        if (parsed !== null) {
          return parsed;
        }
      }
    }
    return null;
  }

  /**
   * 解析 `upload=..; download=..; total=..; expire=..`。
   * 字段可能缺失或顺序不一，因此按 key 逐项认，认不出就留未知。
   * expire 可能是秒（10 位）或毫秒（13 位）时间戳，按量级归一。
   */
  private parseUsageString(text: string): SubscriptionUsage | null {
    const parts: string[] = text.split(';');
    let upload: number = 0;
    let download: number = 0;
    let total: number = 0;
    let expireMs: number = 0;
    let found: boolean = false;
    for (let i = 0; i < parts.length; i++) {
      const seg: string = parts[i].trim();
      const eq: number = seg.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const key: string = seg.substring(0, eq).trim().toLowerCase();
      const value: number = Number(seg.substring(eq + 1).trim());
      if (Number.isNaN(value)) {
        continue;
      }
      if (key === 'upload') {
        upload = value > 0 ? value : 0;
        found = true;
      } else if (key === 'download') {
        download = value > 0 ? value : 0;
        found = true;
      } else if (key === 'total') {
        total = value > 0 ? value : 0;
        found = true;
      } else if (key === 'expire') {
        expireMs = value > 100000000000 ? Math.floor(value) : Math.floor(value * 1000);
        found = true;
      }
    }
    if (!found) {
      return null;
    }
    return this.buildUsage(upload, download, total, expireMs);
  }

  /** 把原始字节/时间戳归一成 SubscriptionUsage（total=0 视为未提供） */
  private buildUsage(upload: number, download: number, total: number, expireMs: number): SubscriptionUsage {
    const used: number = upload + download;
    const hasTotal: boolean = total > 0;
    let remaining: number = hasTotal ? total - used : -1;
    if (hasTotal && remaining < 0) {
      remaining = 0;
    }
    return {
      upload: upload,
      download: download,
      total: hasTotal ? total : -1,
      used: used,
      remaining: remaining,
      expireMs: expireMs > 0 ? expireMs : 0,
      updatedAt: Date.now()
    };
  }

  private detectFormat(content: string): string {
    const trimmed = content.trim();
    if (trimmed.length === 0) {
      return 'unsupported';
    }
    // 顺序很重要：先 YAML（避免 YAML 注释里恰好有 ss:// 被误判为分享链接），
    // 再裸分享链接，最后 base64（解出来可能是链接列表，也可能是 YAML）。
    if (this.looksLikeClashYaml(trimmed)) {
      return 'clash-yaml';
    }
    if (this.hasShareLink(trimmed)) {
      return 'share-links';
    }
    const decoded = this.tryDecodeBase64(trimmed);
    if (decoded.length > 0) {
      if (this.hasShareLink(decoded)) {
        return 'base64-links';
      }
      if (this.looksLikeClashYaml(decoded.trim())) {
        return 'base64-yaml';
      }
    }
    return 'unsupported';
  }

  /** 顶格键扫描：跳过注释/空行/缩进行，命中任一 Clash 顶层键即认定 YAML */
  private looksLikeClashYaml(text: string): boolean {
    const lines = text.split('\n');
    const limit: number = Math.min(lines.length, 300);
    for (let i = 0; i < limit; i++) {
      const line: string = lines[i];
      if (line.length === 0 || line.startsWith('#')) {
        continue;
      }
      const c: number = line.charCodeAt(0);
      if (c === 32 || c === 9) {
        continue;
      }
      for (let k = 0; k < CLASH_YAML_KEYS.length; k++) {
        if (line.startsWith(CLASH_YAML_KEYS[k])) {
          return true;
        }
      }
    }
    return false;
  }

  /** 统计 `proxy-providers:` 下的条目数（二级缩进的 `名字:` 行） */
  private countProxyProviders(content: string): number {
    const lines = content.split('\n');
    let count: number = 0;
    let inProviders: boolean = false;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      if (line.startsWith('proxy-providers:')) {
        inProviders = true;
        continue;
      }
      if (!inProviders) {
        continue;
      }
      if (line.length === 0 || line.startsWith('#')) {
        continue;
      }
      const c: number = line.charCodeAt(0);
      if (c !== 32 && c !== 9) {
        break;
      }
      const t: string = line.trim();
      if (t.endsWith(':') && t.indexOf(' ') < 0) {
        count++;
      }
    }
    return count;
  }

  private hasShareLink(content: string): boolean {
    const schemes: string[] = ['ss://', 'vmess://', 'vless://', 'trojan://', 'hysteria2://', 'tuic://'];
    for (let i = 0; i < schemes.length; i++) {
      if (content.indexOf(schemes[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  private tryDecodeBase64(content: string): string {
    try {
      const decoded = new util.Base64Helper().decodeSync(content);
      return buffer.from(decoded).toString('utf8');
    } catch (_err) {
      return '';
    }
  }

  private parseNodes(content: string, format: string): ProxyNode[] {
    if (format === 'clash-yaml') {
      return this.parseYamlNodes(content);
    }
    let text = content;
    if (format === 'base64-links') {
      text = this.tryDecodeBase64(content);
    }
    return this.parseShareNodes(text);
  }

  private parseYamlNodes(content: string): ProxyNode[] {
    const lines = content.split('\n');
    const nodes: ProxyNode[] = [];
    let index = 0;
    let inProxies: boolean = false;
    for (let i = 0; i < lines.length; i++) {
      const raw: string = lines[i];
      // 顶格键切换状态：只统计 `proxies:` 段内的 `- name:`。
      // 否则 proxy-groups / rule-providers 的条目名会被当成代理节点
      // （实测：2 节点 + 1 策略组的测试订阅被数成 3 节点）。
      if (raw.length > 0 && raw.charCodeAt(0) !== 32 && raw.charCodeAt(0) !== 9) {
        inProxies = raw.startsWith('proxies:');
      }
      const line = raw.trim();
      if (inProxies && line.startsWith('- name:')) {
        let rawName = line.substring(7).trim();
        if (rawName.length >= 2 &&
          ((rawName.startsWith('"') && rawName.endsWith('"')) ||
            (rawName.startsWith('\'') && rawName.endsWith('\'')))) {
          rawName = rawName.substring(1, rawName.length - 1);
        }
        const name = rawName.length > 0 ? rawName : '节点 ' + (index + 1);
        nodes.push({
          name: name,
          protocol: this.protocolFromYaml(lines, i),
          group: '导入节点',
          latency: -1,
          selected: index === 0
        });
        index++;
      }
    }
    return nodes;
  }

  private protocolFromYaml(lines: string[], start: number): string {
    const end = Math.min(start + 8, lines.length);
    for (let i = start + 1; i < end; i++) {
      const line = lines[i].trim();
      if (line.startsWith('type:')) {
        return line.substring(5).trim();
      }
    }
    return 'unknown';
  }

  private parseShareNodes(content: string): ProxyNode[] {
    const lines = content.split('\n');
    const nodes: ProxyNode[] = [];
    let index = 0;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!this.hasShareLink(line)) {
        continue;
      }
      const protocol = this.shareProtocol(line);
      const name = this.shareName(line, protocol, index);
      if (index === 0) {
        hilog.info(DOMAIN, TAG, 'sample link[0] protocol=%{public}s', protocol);
      }
      nodes.push({
        name: name,
        protocol: protocol,
        group: '分享链接',
        latency: -1,
        selected: index === 0,
        link: line
      });
      index++;
    }
    return nodes;
  }

  private shareProtocol(link: string): string {
    const schemes: string[] = ['ss://', 'vmess://', 'vless://', 'trojan://', 'hysteria2://', 'tuic://'];
    for (let i = 0; i < schemes.length; i++) {
      if (link.startsWith(schemes[i])) {
        return schemes[i].substring(0, schemes[i].length - 3);
      }
    }
    return 'unknown';
  }

  private shareName(link: string, protocol: string, index: number): string {
    const hashIndex = link.lastIndexOf('#');
    if (hashIndex >= 0 && hashIndex < link.length - 1) {
      const raw = link.substring(hashIndex + 1);
      if (raw.length > 0 && raw.indexOf('://') < 0) {
        return this.tryDecodeName(raw);
      }
    }
    if (protocol === 'vmess') {
      const payload = link.substring('vmess://'.length);
      const decoded = this.tryDecodeBase64(payload);
      try {
        const obj = JSON.parse(decoded) as Record<string, string>;
        const ps = obj['ps'];
        if (ps !== undefined && ps.length > 0) {
          return this.tryDecodeName(ps);
        }
      } catch (_err) {
      }
    }
    return protocol.toUpperCase() + ' ' + (index + 1);
  }

  private tryDecodeName(name: string): string {
    try {
      const decoded = decodeURIComponent(name);
      return decoded.length > 0 ? decoded : name;
    } catch (_err) {
      return name;
    }
  }

  private formatLabel(format: string): string {
    if (format === 'clash-yaml') {
      return 'Clash / Mihomo YAML 已识别';
    }
    if (format === 'base64-links') {
      return 'Base64 分享订阅已识别';
    }
    if (format === 'share-links') {
      return '分享链接已识别';
    }
    return '不支持';
  }

  private saveProfiles(profiles: SubscriptionProfile[]): void {
    try {
      this.store.putSync(KEY_PROFILES, JSON.stringify(profiles));
      let activeId = '';
      for (let i = 0; i < profiles.length; i++) {
        if (profiles[i].active) {
          activeId = profiles[i].id;
        }
      }
      this.store.putSync(KEY_ACTIVE_ID, activeId);
      this.store.flush();
    } catch (_err) {
      throw new Error('订阅元数据保存失败');
    }
  }

  private isValidProfile(profile: SubscriptionProfile): boolean {
    if (profile === null || profile === undefined) {
      return false;
    }
    if (typeof profile.id !== 'string' || profile.id.length === 0) {
      return false;
    }
    if (typeof profile.name !== 'string' || typeof profile.detectedFormat !== 'string') {
      return false;
    }
    return true;
  }

  private contentPath(id: string): string {
    const dir = this.context.filesDir + SUB_DIR;
    this.ensureDir(dir, '订阅存储目录创建失败');
    return dir + '/' + id + '.conf';
  }

  private ensureDir(dir: string, message: string): void {
    try {
      fileIo.mkdirSync(dir, true);
      return;
    } catch (_err) {
      try {
        fileIo.accessSync(dir);
        return;
      } catch (_inner) {
        throw new Error(message);
      }
    }
  }

  private writeContent(id: string, content: string): void {
    const path = this.contentPath(id);
    let fd = -1;
    try {
      const f = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
      fd = f.fd;
      fileIo.writeSync(fd, content);
    } catch (_err) {
      throw new Error('订阅内容写入失败');
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (_err) {
        }
      }
    }
  }

  private deleteContent(id: string): void {
    try {
      fileIo.unlinkSync(this.contentPath(id));
    } catch (_err) {
    }
  }

  private newId(): string {
    return Date.now().toString(36) + Math.random().toString(36).substring(2, 8);
  }
}
