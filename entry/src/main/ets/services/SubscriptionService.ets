import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import fileIo from '@ohos.file.fs';
import { http } from '@kit.NetworkKit';
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

  private async fetchSubscription(url: string): Promise<FetchResult> {
    const req = http.createHttp();
    try {
      const response = await req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 30000,
        connectTimeout: 10000,
        header: {
          'User-Agent': UA,
          'Accept': ACCEPT
        }
      });
      const status = response.responseCode;
      if (status < 200 || status >= 300) {
        throw new Error('HTTP ' + status);
      }
      const content = response.result as string;
      // 用量：优先读响应头 subscription-userinfo（机场通用约定），
      // 头里没有时再退一步扫正文注释（少数机场把用量写成注释）。
      let usage: SubscriptionUsage | null = this.usageFromHeaders(response.header);
      if (usage === null) {
        usage = this.usageFromBody(content);
      }
      return { content: content, usage: usage };
    } catch (err) {
      if (err instanceof Error && err.message.startsWith('HTTP ')) {
        throw err;
      }
      throw new Error('订阅下载失败，请检查网络和链接');
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
