import { http } from '@kit.NetworkKit';
import fileIo from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x2026;
const TAG = 'LianReport';
const CONFIG_FILE = '/lian-report.json';
const STATUS_FILE = '/lian-report-status.json';

/**
 * 流量去向回传模块（自用）。
 *
 * 挂载点：LianVpnAbility 的 1 秒轮询已经把每条连接的
 * host / destination / 命中规则 / 代理链 / 上下行字节 写进
 * core-connections.json，这里取同一份数据做增量上报。
 *
 * 为什么放在 VPN 扩展进程而不是 UI 进程：
 * - 扩展进程常驻（UI 进程退后台会被系统回收）；
 * - protectProcessNet() 已让本进程 socket 绕开隧道，回传不会回环；
 * - 本应用包名也在 blockedApplications 里，双重保险。
 *
 * 开关（配置级，默认开启）：应用沙箱 filesDir/lian-report.json
 *   { "enabled": true, "endpoint": "http://192.168.1.100:18820/ingest", ... }
 * enabled=false 或删除 endpoint 即完全静默；文件不存在时用下面默认值并自动落盘。
 */

/** 与 core/bridge.go 的 connPayload 对应（数值/字符串都可能缺省） */
interface ReportConn {
  id?: string;
  host?: string;
  destination?: string;
  network?: string;
  rule?: string;
  rulePayload?: string;
  chains?: string[];
  up?: number;
  down?: number;
  startMs?: number;
  proxied?: boolean;
}

/** lian-report.json 的结构（所有字段可省略，省略即用默认） */
interface ReportConfig {
  enabled?: boolean;
  endpoint?: string;
  /** Bearer token：与电脑端接收服务 --token 一致；置空串则不发鉴权头 */
  token?: string;
  intervalSeconds?: number;
  device?: string;
  includeDirect?: boolean;
  minDeltaBytes?: number;
  maxBatch?: number;
}

interface ReportEvent {
  ev: string;
  ts: number;
  id: string;
  host: string;
  destination: string;
  network: string;
  rule: string;
  rulePayload: string;
  chains: string[];
  up: number;
  down: number;
  startMs: number;
  proxied: boolean;
  from?: string;
  to?: string;
  reason?: string;
}

interface ReportPayload {
  device: string;
  ts: number;
  events: ReportEvent[];
}

const DEFAULT_ENDPOINT: string = 'http://192.168.1.100:18820/ingest';
/** 局域网回传鉴权 token：与 pc-side/report-server.mjs --token 成对修改后重新构建 */
const DEFAULT_TOKEN: string = '';

export class TrafficReporter {
  private filesDir: string;
  private enabled: boolean = true;
  private endpoint: string = DEFAULT_ENDPOINT;
  private token: string = DEFAULT_TOKEN;
  private intervalMs: number = 2000;
  private deviceTag: string = 'xiaobai-clash';
  private includeDirect: boolean = true;
  private minDeltaBytes: number = 0;
  private maxBatch: number = 40;
  private loaded: boolean = false;
  private sending: boolean = false;
  private lastSentAt: number = 0;
  /** id -> 上次已上报的 up+down 总量，用于增量判定 */
  private lastTotals: Map<string, number> = new Map();
  /** id -> 上次看到的完整连接，用于闭合连接时补全 end 事件 */
  private lastSeen: Map<string, ReportConn> = new Map();
  private totalSent: number = 0;
  private lastError: string = '';

  constructor(filesDir: string) {
    this.filesDir = filesDir;
  }

  private loadConfig(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    try {
      const raw: string = fileIo.readTextSync(this.filesDir + CONFIG_FILE);
      const parsed = JSON.parse(raw) as ReportConfig;
      if (parsed !== null && parsed !== undefined) {
        if (parsed.enabled !== undefined) {
          this.enabled = parsed.enabled === true;
        }
        if (typeof parsed.endpoint === 'string' && parsed.endpoint.length > 0) {
          this.endpoint = parsed.endpoint;
        }
        if (typeof parsed.token === 'string') {
          // 允许显式置空：空串 = 不发 Authorization 头（兼容无鉴权的接收端）
          this.token = parsed.token;
        }
        if (typeof parsed.intervalSeconds === 'number' && parsed.intervalSeconds >= 1) {
          this.intervalMs = parsed.intervalSeconds * 1000;
        }
        if (typeof parsed.device === 'string' && parsed.device.length > 0) {
          this.deviceTag = parsed.device;
        }
        if (parsed.includeDirect !== undefined) {
          this.includeDirect = parsed.includeDirect !== false;
        }
        if (typeof parsed.minDeltaBytes === 'number' && parsed.minDeltaBytes >= 0) {
          this.minDeltaBytes = parsed.minDeltaBytes;
        }
        if (typeof parsed.maxBatch === 'number' && parsed.maxBatch >= 1 && parsed.maxBatch <= 100) {
          this.maxBatch = parsed.maxBatch;
        }
      }
      hilog.info(DOMAIN, TAG, 'report config loaded endpoint=%{public}s enabled=%{public}s',
        this.endpoint, this.enabled ? '1' : '0');
    } catch (_err) {
      // 首次运行：把默认配置落盘，之后可在沙箱内直接改（开关就是这个文件）
      const defaults: ReportConfig = {
        enabled: true,
        endpoint: DEFAULT_ENDPOINT,
        token: DEFAULT_TOKEN,
        intervalSeconds: 2,
        device: 'xiaobai-clash',
        includeDirect: true,
        minDeltaBytes: 0,
        maxBatch: 40
      };
      this.writeText(this.filesDir + CONFIG_FILE, JSON.stringify(defaults));
      hilog.info(DOMAIN, TAG, 'report config missing; defaults written');
    }
  }

  /**
   * 每个轮询周期调用；内部按 intervalMs 节流。
   * 上报失败不更新增量记账，下个周期自然重传（连接对象本身仍活跃）。
   */
  async maybeReport(connectionsJson: string): Promise<void> {
    this.loadConfig();
    if (!this.enabled || this.sending || this.endpoint.length === 0) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastSentAt < this.intervalMs) {
      return;
    }
    let list: ReportConn[] = [];
    try {
      const parsed = JSON.parse(connectionsJson) as ReportConn[];
      if (!Array.isArray(parsed)) {
        return;
      }
      list = parsed;
    } catch (_err) {
      return;
    }

    const events: ReportEvent[] = [];
    const currentIds: Set<string> = new Set();
    for (let i = 0; i < list.length && events.length < this.maxBatch; i++) {
      const c: ReportConn = list[i];
      const id: string = c.id ?? '';
      if (id.length === 0) {
        continue;
      }
      if (!this.includeDirect && c.proxied !== true) {
        continue;
      }
      currentIds.add(id);
      const total: number = (c.up ?? 0) + (c.down ?? 0);
      const prevTotal: number | undefined = this.lastTotals.get(id);
      const isNew: boolean = prevTotal === undefined;
      const grew: boolean = prevTotal !== undefined && total > prevTotal + this.minDeltaBytes;
      if (isNew || grew) {
        events.push({
          ev: isNew ? 'conn' : 'update',
          ts: now,
          id: id,
          host: c.host ?? '',
          destination: c.destination ?? '',
          network: c.network ?? '',
          rule: c.rule ?? '',
          rulePayload: c.rulePayload ?? '',
          chains: c.chains ?? [],
          up: c.up ?? 0,
          down: c.down ?? 0,
          startMs: c.startMs ?? 0,
          proxied: c.proxied === true
        });
      }
    }

    // 闭合连接：此前上报过、本轮不再出现 → 发 end 事件（带最后一次快照）
    const endedIds: string[] = [];
    this.lastTotals.forEach((_v: number, k: string) => {
      if (!currentIds.has(k)) {
        endedIds.push(k);
      }
    });
    for (let i = 0; i < endedIds.length && events.length < this.maxBatch; i++) {
      const id: string = endedIds[i];
      const last: ReportConn | undefined = this.lastSeen.get(id);
      events.push({
        ev: 'end',
        ts: now,
        id: id,
        host: last?.host ?? '',
        destination: last?.destination ?? '',
        network: last?.network ?? '',
        rule: last?.rule ?? '',
        rulePayload: last?.rulePayload ?? '',
        chains: last?.chains ?? [],
        up: last?.up ?? 0,
        down: last?.down ?? 0,
        startMs: last?.startMs ?? 0,
        proxied: last?.proxied === true
      });
    }

    if (events.length === 0) {
      return;
    }
    const payload: ReportPayload = { device: this.deviceTag, ts: now, events: events };
    this.sending = true;
    this.lastSentAt = now;
    let ok: boolean = false;
    try {
      const req = http.createHttp();
      try {
        const resp = await req.request(this.endpoint, {
          method: http.RequestMethod.POST,
          header: this.buildHeader(),
          extraData: JSON.stringify(payload),
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 8000,
          readTimeout: 8000
        });
        if (resp.responseCode >= 200 && resp.responseCode < 300) {
          ok = true;
          this.lastError = '';
        } else {
          this.lastError = 'HTTP ' + resp.responseCode;
        }
      } finally {
        req.destroy();
      }
    } catch (_err) {
      this.lastError = 'request failed';
      hilog.warn(DOMAIN, TAG, 'report send failed');
    }

    if (ok) {
      for (let i = 0; i < list.length; i++) {
        const c: ReportConn = list[i];
        const id: string = c.id ?? '';
        if (id.length === 0) {
          continue;
        }
        this.lastTotals.set(id, (c.up ?? 0) + (c.down ?? 0));
        this.lastSeen.set(id, c);
      }
      for (let i = 0; i < endedIds.length; i++) {
        this.lastTotals.delete(endedIds[i]);
        this.lastSeen.delete(endedIds[i]);
      }
      this.totalSent += events.length;
      hilog.info(DOMAIN, TAG, 'report ok events=%{public}d', events.length);
    }
    this.sending = false;
    this.writeStatus(now);
  }

  /**
   * 推送一条 node_switch 事件到电脑端（AutoNodeSwitcher 使用）。
   * 与连接上报同一条管道，但不受增量节流约束；回传关闭时静默跳过。
   */
  async sendSwitch(fromName: string, toName: string, reason: string): Promise<void> {
    this.loadConfig();
    if (!this.enabled || this.endpoint.length === 0) {
      return;
    }
    const now: number = Date.now();
    const evt: ReportEvent = {
      ev: 'node_switch', ts: now, id: 'switch-' + now, host: '', destination: '',
      network: '', rule: '', rulePayload: '', chains: [], up: 0, down: 0, startMs: 0,
      proxied: true, from: fromName, to: toName, reason: reason
    };
    const events: ReportEvent[] = [evt];
    const payload: ReportPayload = { device: this.deviceTag, ts: now, events: events };
    try {
      const req = http.createHttp();
      try {
        await req.request(this.endpoint, {
          method: http.RequestMethod.POST,
          header: this.buildHeader(),
          extraData: JSON.stringify(payload),
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 8000,
          readTimeout: 8000
        });
      } finally {
        req.destroy();
      }
    } catch (_err) {
      // 切换事件尽力而为，失败不影响主流程
    }
  }

  /** 统一构造请求头：token 非空时附加 Bearer 鉴权（连接上报与切换事件共用） */
  private buildHeader(): Record<string, string> {
    const header: Record<string, string> = { 'Content-Type': 'application/json' };
    if (this.token.length > 0) {
      header['Authorization'] = 'Bearer ' + this.token;
    }
    return header;
  }

  private writeStatus(now: number): void {
    const status: string = JSON.stringify({
      endpoint: this.endpoint,
      enabled: this.enabled,
      lastAttemptAt: now,
      totalSent: this.totalSent,
      lastError: this.lastError
    });
    this.writeText(this.filesDir + STATUS_FILE, status);
  }

  /** 原子写：临时文件 + rename；失败退回直写。诊断文件写不进不影响主流程 */
  private writeText(path: string, content: string): void {
    const tmp: string = path + '.tmp';
    try {
      const f = fileIo.openSync(tmp,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
      try {
        fileIo.writeSync(f.fd, content);
      } finally {
        fileIo.closeSync(f);
      }
      try {
        fileIo.renameSync(tmp, path);
        return;
      } catch (_err) {
        // rename 不被允许时退回直接写入
      }
    } catch (_err) {
      // fall through
    }
    try {
      const f2 = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
      try {
        fileIo.writeSync(f2.fd, content);
      } finally {
        fileIo.closeSync(f2);
      }
    } catch (_err2) {
      // 尽力而为
    }
  }
}
