import { http } from '@kit.NetworkKit';
import fileIo from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TrafficReporter } from './TrafficReporter';

const DOMAIN = 0x2028;
const TAG = 'AutoSwitch';
const CONFIG_FILE = '/lian-nodeswitch.json';
const STATUS_FILE = '/lian-nodeswitch-status.json';
const LOG_FILE = '/lian-nodeswitch-log.jsonl';
const MANUAL_GROUP = '手动选择';

/**
 * 节点自动体检 + 故障自动切换（纯 ArkTS，走 mihomo 本地控制端口）。
 *
 * 原理：ConfigService 生成的配置固定启用 external-controller 127.0.0.1:9090，
 * 且 MATCH → 「手动选择」selector 组（默认成员是「自动选择」url-test 组）。
 * 因此无需重编 Go 内核：
 *   - GET  /proxies                    全量代理树（含每节点 history）
 *   - GET  /proxies/{name}/delay       单节点/单组真实 URLTest
 *   - PUT  /proxies/{group} {"name":x} 切换出口（与 UI 手动选择同一语义）
 *
 * 策略（默认开启，配置文件 lian-nodeswitch.json）：
 *   每 intervalSeconds 探测当前有效节点；连续 failThreshold 次失败
 *   → 扫描组内候选（按最近 history 排序，最多 maxTest 个，8 路并发）
 *   → 切到最快存活节点，记录日志并推送 node_switch 事件到电脑端。
 * 「自动选择」url-test 组由内核自愈，这里只在整组无存活时才手动接管
 * （auto→manual rescue），避免频繁抢方向盘。
 * 直接锁定某节点不想被自动切换：把 enabled 置 false。
 * 探测经保护套接字绕开 TUN，不会形成回环。
 */

interface ProbeHistory {
  time?: string;
  delay?: number;
}

interface ControllerNode {
  name?: string;
  type?: string;
  now?: string;
  all?: string[];
  history?: ProbeHistory[];
}

interface ControllerResp {
  proxies?: Record<string, ControllerNode>;
}

/** PUT /proxies/{group} 的请求体（ArkTS 禁止未声明类型的对象字面量） */
interface SwitchBody {
  name: string;
}

interface SwitchConfig {
  enabled?: boolean;
  controller?: string;
  intervalSeconds?: number;
  failThreshold?: number;
  probeTimeoutMs?: number;
  switchCooldownSeconds?: number;
  maxTest?: number;
  testUrl?: string;
}

export class AutoNodeSwitcher {
  private filesDir: string;
  private reporter: TrafficReporter | undefined = undefined;
  private cfg: SwitchConfig = {};
  private loaded: boolean = false;
  private busy: boolean = false;
  private lastCheckAt: number = 0;
  private lastSwitchAt: number = 0;
  private failStreak: number = 0;
  private lastError: string = '';

  constructor(filesDir: string, reporter: TrafficReporter | undefined) {
    this.filesDir = filesDir;
    this.reporter = reporter;
  }

  private defaults(): void {
    this.cfg.enabled = true;
    this.cfg.controller = 'http://127.0.0.1:9090';
    this.cfg.intervalSeconds = 60;
    this.cfg.failThreshold = 2;
    this.cfg.probeTimeoutMs = 5000;
    this.cfg.switchCooldownSeconds = 180;
    this.cfg.maxTest = 40;
    this.cfg.testUrl = 'http://www.gstatic.com/generate_204';
  }

  private loadConfig(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    this.defaults();
    try {
      const raw: string = fileIo.readTextSync(this.filesDir + CONFIG_FILE);
      const parsed = JSON.parse(raw) as SwitchConfig;
      if (parsed !== null && parsed !== undefined) {
        if (parsed.enabled !== undefined) {
          this.cfg.enabled = parsed.enabled === true;
        }
        if (typeof parsed.controller === 'string' && parsed.controller.length > 0) {
          this.cfg.controller = parsed.controller;
        }
        if (typeof parsed.intervalSeconds === 'number' && parsed.intervalSeconds >= 10) {
          this.cfg.intervalSeconds = parsed.intervalSeconds;
        }
        if (typeof parsed.failThreshold === 'number' && parsed.failThreshold >= 1) {
          this.cfg.failThreshold = parsed.failThreshold;
        }
        if (typeof parsed.probeTimeoutMs === 'number' && parsed.probeTimeoutMs >= 1000) {
          this.cfg.probeTimeoutMs = parsed.probeTimeoutMs;
        }
        if (typeof parsed.switchCooldownSeconds === 'number' && parsed.switchCooldownSeconds >= 0) {
          this.cfg.switchCooldownSeconds = parsed.switchCooldownSeconds;
        }
        if (typeof parsed.maxTest === 'number' && parsed.maxTest >= 1 && parsed.maxTest <= 100) {
          this.cfg.maxTest = parsed.maxTest;
        }
        if (typeof parsed.testUrl === 'string' && parsed.testUrl.length > 0) {
          this.cfg.testUrl = parsed.testUrl;
        }
      }
      hilog.info(DOMAIN, TAG, 'autoswitch config loaded');
    } catch (_err) {
      const text: string = JSON.stringify(this.cfg);
      this.writeText(this.filesDir + CONFIG_FILE, text);
      hilog.info(DOMAIN, TAG, 'autoswitch config missing; defaults written');
    }
  }

  /** 每秒由扩展轮询调用；内部按 intervalSeconds 节流 */
  async tick(mode: string): Promise<void> {
    this.loadConfig();
    if (this.cfg.enabled !== true || this.busy) {
      return;
    }
    if (mode === 'direct') {
      return;
    }
    const now: number = Date.now();
    const intervalMs: number = (this.cfg.intervalSeconds ?? 60) * 1000;
    if (now - this.lastCheckAt < intervalMs) {
      return;
    }
    this.lastCheckAt = now;
    this.busy = true;
    try {
      await this.runCycle(mode, now);
    } catch (_err) {
      this.lastError = 'cycle failed';
    }
    this.busy = false;
    this.writeStatus(now);
  }

  private async runCycle(mode: string, now: number): Promise<void> {
    const base: string = this.cfg.controller ?? 'http://127.0.0.1:9090';
    const root: ControllerResp | null = await this.getJson(base + '/proxies');
    if (root === null || root.proxies === undefined || root.proxies === null) {
      this.lastError = 'controller unreachable';
      return;
    }
    const groupName: string = this.pickGroup(root, mode);
    const group: ControllerNode | undefined = this.getNode(root, groupName);
    if (groupName.length === 0 || group === undefined) {
      this.lastError = 'no managed group';
      return;
    }
    const nowName: string = group.now ?? '';
    if (nowName.length === 0) {
      return;
    }
    const nowNode: ControllerNode | undefined = this.getNode(root, nowName);
    const isNestedGroup: boolean = nowNode !== undefined && this.isGroupType(nowNode.type ?? '');

    if (isNestedGroup) {
      // 「自动选择」url-test 在位：内核每连接自行择优，只有整组全灭才接管
      const groupDelay: number = await this.probe(base, nowName);
      if (groupDelay >= 0) {
        this.failStreak = 0;
        return;
      }
      this.failStreak++;
      if (this.failStreak < (this.cfg.failThreshold ?? 2)
        || now - this.lastSwitchAt < (this.cfg.switchCooldownSeconds ?? 180) * 1000) {
        this.lastError = 'auto group failing, streak=' + this.failStreak;
        return;
      }
      const leaves: string[] = this.collectLeaves(root, nowName, 64);
      const best: string | null = await this.scanBest(base, leaves, '');
      if (best !== null) {
        await this.applySwitch(base, groupName, best, 'auto-dead-rescue');
        this.lastError = '';
      } else {
        this.lastError = 'all nodes dead';
      }
      return;
    }

    // 用户锁定在具体节点：探测该节点，故障则换最快存活节点
    const delay: number = await this.probe(base, nowName);
    if (delay >= 0) {
      if (this.failStreak !== 0) {
        hilog.info(DOMAIN, TAG, 'node %{public}s healthy again delay=%{public}d', nowName, delay);
      }
      this.failStreak = 0;
      return;
    }
    this.failStreak++;
    this.lastError = 'node ' + nowName + ' dead, streak=' + this.failStreak;
    hilog.warn(DOMAIN, TAG, 'probe fail %{public}s streak=%{public}d', nowName, this.failStreak);
    if (this.failStreak < (this.cfg.failThreshold ?? 2)) {
      return;
    }
    if (now - this.lastSwitchAt < (this.cfg.switchCooldownSeconds ?? 180) * 1000) {
      return;
    }
    const all: string[] = group.all ?? [];
    const candidates: string[] = [];
    for (let i = 0; i < all.length; i++) {
      const name: string = all[i];
      if (name === nowName) {
        continue;
      }
      const node: ControllerNode | undefined = this.getNode(root, name);
      if (node === undefined || this.isGroupType(node.type ?? '')) {
        continue;
      }
      candidates.push(name);
    }
    // 按最近 history 延迟排序，最快者优先，截断到 maxTest
    const sorted: string[] = candidates.sort((a: string, b: string): number => {
      return this.recentDelay(root, a) - this.recentDelay(root, b);
    });
    const limit: number = this.cfg.maxTest ?? 40;
    const head: string[] = sorted.length > limit ? sorted.slice(0, limit) : sorted;
    const best2: string | null = await this.scanBest(base, head, nowName);
    if (best2 !== null) {
      await this.applySwitch(base, groupName, best2, 'node-dead');
      this.lastError = '';
    } else {
      this.lastError = 'no alive node among candidates';
      hilog.warn(DOMAIN, TAG, 'no alive candidate, keep current node');
    }
  }

  /** 8 路并发分批探测，返回最快存活节点名；没有则 null */
  private async scanBest(base: string, names: string[], exclude: string): Promise<string | null> {
    let bestName: string = '';
    let bestDelay: number = -1;
    const batch: number = 8;
    for (let i = 0; i < names.length; i += batch) {
      const end: number = Math.min(i + batch, names.length);
      const chunk: string[] = names.slice(i, end);
      const tasks: Promise<number>[] = [];
      for (let k = 0; k < chunk.length; k++) {
        tasks.push(this.probe(base, chunk[k]));
      }
      const results: number[] = await Promise.all(tasks);
      for (let k = 0; k < chunk.length; k++) {
        const d: number = results[k];
        if (d >= 0 && (bestDelay < 0 || d < bestDelay)) {
          bestDelay = d;
          bestName = chunk[k];
        }
      }
    }
    if (bestName.length === 0 || bestName === exclude) {
      return null;
    }
    return bestName;
  }

  private async applySwitch(base: string, groupName: string, toName: string, reason: string): Promise<void> {
    const url: string = base + '/proxies/' + encodeURIComponent(groupName);
    const switchBody: SwitchBody = { name: toName };
    const body: string = JSON.stringify(switchBody);
    const code: number = await this.put(url, body);
    if (code < 200 || code >= 300) {
      this.lastError = 'PUT failed http ' + code;
      return;
    }
    this.failStreak = 0;
    this.lastSwitchAt = Date.now();
    const line: string = JSON.stringify({
      ts: Date.now(), group: groupName, to: toName, reason: reason
    });
    this.appendLine(this.filesDir + LOG_FILE, line);
    hilog.info(DOMAIN, TAG, 'node switched to %{public}s reason=%{public}s', toName, reason);
    const rep: TrafficReporter | undefined = this.reporter;
    if (rep !== undefined) {
      rep.sendSwitch(groupName, toName, reason).catch((_e: Error) => {
        hilog.warn(DOMAIN, TAG, 'switch event push failed');
      });
    }
  }

  /** 单节点/单组真实 URLTest；返回延迟毫秒，失败 -1 */
  private async probe(base: string, name: string): Promise<number> {
    const url: string = base + '/proxies/' + encodeURIComponent(name)
      + '/delay?timeout=' + (this.cfg.probeTimeoutMs ?? 5000)
      + '&url=' + encodeURIComponent(this.cfg.testUrl ?? 'http://www.gstatic.com/generate_204');
    const got: HttpText | null = await this.rawGet(url);
    if (got === null || got.code < 200 || got.code >= 300) {
      return -1;
    }
    try {
      const obj = JSON.parse(got.body) as Record<string, number>;
      const d: number | undefined = obj['delay'];
      return d === undefined ? -1 : d;
    } catch (_err) {
      return -1;
    }
  }

  private pickGroup(root: ControllerResp, mode: string): string {
    if (mode === 'global' && this.getNode(root, 'GLOBAL') !== undefined) {
      return 'GLOBAL';
    }
    if (this.getNode(root, MANUAL_GROUP) !== undefined) {
      return MANUAL_GROUP;
    }
    // 回退：成员最多的非内置 select/url-test 组（对齐 Go 侧 largestRoutingGroup）
    const map: Record<string, ControllerNode> = root.proxies ?? {};
    let best: string = '';
    let bestCount: number = -1;
    const keys: string[] = Object.keys(map);
    for (let i = 0; i < keys.length; i++) {
      const name: string = keys[i];
      if (this.isBuiltin(name)) {
        continue;
      }
      const node: ControllerNode | undefined = map[name];
      if (node === undefined || !this.isGroupType(node.type ?? '')) {
        continue;
      }
      const c: number = node.all?.length ?? 0;
      if (c > bestCount) {
        bestCount = c;
        best = name;
      }
    }
    return best;
  }

  private isBuiltin(name: string): boolean {
    return name === 'GLOBAL' || name === 'DIRECT' || name === 'REJECT'
      || name === 'REJECT-DROP' || name === 'PASS' || name === 'COMPATIBLE';
  }

  private isGroupType(t: string): boolean {
    return t === 'select' || t === 'url-test' || t === 'fallback'
      || t === 'load-balance' || t === 'compatible';
  }

  private collectLeaves(root: ControllerResp, groupName: string, cap: number): string[] {
    const out: string[] = [];
    const queue: string[] = [groupName];
    const seen: Set<string> = new Set();
    while (queue.length > 0 && out.length < cap) {
      const cur: string = queue.shift() ?? '';
      if (cur.length === 0 || seen.has(cur)) {
        continue;
      }
      seen.add(cur);
      const node: ControllerNode | undefined = this.getNode(root, cur);
      if (node === undefined) {
        continue;
      }
      if (this.isGroupType(node.type ?? '')) {
        const all: string[] = node.all ?? [];
        for (let i = 0; i < all.length; i++) {
          queue.push(all[i]);
        }
      } else {
        out.push(cur);
      }
    }
    return out;
  }

  /** 最近一次 history 延迟；未知/失败按 1e9 排最后 */
  private recentDelay(root: ControllerResp, name: string): number {
    const node: ControllerNode | undefined = this.getNode(root, name);
    if (node === undefined) {
      return 1000000000;
    }
    const h: ProbeHistory[] | undefined = node.history;
    if (h === undefined || h.length === 0) {
      return 1000000000;
    }
    const d: number | undefined = h[0]?.delay;
    if (d === undefined || d <= 0) {
      return 1000000000;
    }
    return d;
  }

  private getNode(root: ControllerResp, name: string): ControllerNode | undefined {
    const map: Record<string, ControllerNode> | undefined = root.proxies;
    if (map === undefined || map === null) {
      return undefined;
    }
    const v: ControllerNode | undefined = map[name];
    return (v === undefined || v === null) ? undefined : v;
  }

  private async getJson(url: string): Promise<ControllerResp | null> {
    const got: HttpText | null = await this.rawGet(url);
    if (got === null || got.code < 200 || got.code >= 300) {
      return null;
    }
    try {
      return JSON.parse(got.body) as ControllerResp;
    } catch (_err) {
      return null;
    }
  }

  private async rawGet(url: string): Promise<HttpText | null> {
    try {
      const req = http.createHttp();
      try {
        const resp = await req.request(url, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 3000,
          readTimeout: (this.cfg.probeTimeoutMs ?? 5000) + 3000
        });
        return { code: resp.responseCode, body: resp.result as string };
      } finally {
        req.destroy();
      }
    } catch (_err) {
      return null;
    }
  }

  private async put(url: string, body: string): Promise<number> {
    try {
      const req = http.createHttp();
      try {
        const resp = await req.request(url, {
          method: http.RequestMethod.PUT,
          header: { 'Content-Type': 'application/json' },
          extraData: body,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 3000,
          readTimeout: 5000
        });
        return resp.responseCode;
      } finally {
        req.destroy();
      }
    } catch (_err) {
      return -1;
    }
  }

  private writeStatus(now: number): void {
    const s: string = JSON.stringify({
      enabled: this.cfg.enabled === true,
      lastCheckAt: this.lastCheckAt,
      failStreak: this.failStreak,
      lastSwitchAt: this.lastSwitchAt,
      lastError: this.lastError
    });
    this.writeText(this.filesDir + STATUS_FILE, s);
  }

  private appendLine(path: string, line: string): void {
    try {
      const f = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND | fileIo.OpenMode.WRITE_ONLY);
      try {
        fileIo.writeSync(f.fd, line + '\n');
      } finally {
        fileIo.closeSync(f);
      }
    } catch (_err) {
      // 日志尽力而为
    }
  }

  private writeText(path: string, content: string): void {
    try {
      const f = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
      try {
        fileIo.writeSync(f.fd, content);
      } finally {
        fileIo.closeSync(f);
      }
    } catch (_err) {
      // 尽力而为
    }
  }
}

interface HttpText {
  code: number;
  body: string;
}
