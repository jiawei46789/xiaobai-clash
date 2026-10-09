import { ContentFrame } from '../common/ContentFrame';
import { Fmt } from '../common/Format';
import { ProxyGroup, ProxyNode, SubscriptionProfile, SubscriptionUsage } from '../models/ArkModels';

/** 排序维度：延迟 / 名称 */
type SortKey = 'latency' | 'name';

/** 图标种类（全部用纯形状绘制，见文件末尾 icon()） */
enum IconKind {
  Refresh,
  Plus,
  Search,
  ChevronDown,
  Speed,
  Check
}

/**
 * 节点页。
 *
 * 布局尺寸（vp，依据 440×744 真机视口调试）：
 *  - 订阅条   48  状态点 + 订阅名 + 元信息 + ⟳刷新 + ＋添加
 *  - 工具条   40  搜索框 + 协议筛选 + 延迟/名称分段 + 测速
 *  - 分组头   26  地区名 + 节点数 + 最优延迟（单分组时省略）
 *  - 节点行   44  单行：协议徽标 + 名称 + 延迟 + 选中勾（整行可点），行距 4
 *
 * 相比旧版（操作行 38 + 订阅卡 67 + 搜索行 42 + 分组头 28 + 行距 66）：
 * 列表前置占位 219 → 136 vp，首屏完整节点 5 → 8 行。
 */
@Component
export struct NodesPage {
  @Prop groups: ProxyGroup[] = [];
  @Prop selectedNode: string = '';
  @Prop nodeCount: number = 0;
  @Prop subscriptionName: string = '';
  @Prop importMessage: string = '';
  /** 全部已导入订阅：供「切换」面板列表使用（item.active 标记当前） */
  @Prop subscriptions: SubscriptionProfile[] = [];
  /** 当前订阅的流量用量（来源：订阅响应头 subscription-userinfo）；null=未提供 */
  @Prop usage: SubscriptionUsage | null = null;
  /** 用量是否正在刷新（显示「刷新中」并在卡片上打了暗） */
  @Prop usageRefreshing: boolean = false;
  onRefreshUsage: () => void = () => {
  };
  onSelectNode: (name: string) => void = () => {
  };
  onSelectSubscription: (id: string) => void = () => {
  };
  onImportUrl: (name: string, url: string) => void = () => {
  };
  onImportText: (name: string, content: string) => void = () => {
  };
  onTestNode: (name: string) => void = () => {
  };
  onTestAll: () => void = () => {
  };
  testingAll: boolean = false;
  onRefresh: () => void = () => {
  };

  @State private showImport: boolean = false;
  @State private showSwitcher: boolean = false;
  @State private importName: string = '';
  @State private importUrl: string = '';
  @State private importText: string = '';
  @State private searchText: string = '';
  @State private testingNode: string = '';
  @State private autoTested: boolean = false;
  @State private sortKey: SortKey = 'latency';
  /** 协议筛选：空数组表示不过滤 */
  @State private protocolFilter: string[] = [];
  @State private showProtocolMenu: boolean = false;

  aboutToAppear(): void {
    // 进入页面：若已有节点且尚未自动测速过，自动开始全量测速
    if (!this.autoTested && !this.testingAll && this.hasNodes()) {
      this.autoTested = true;
      this.onTestAll();
    }
  }

  private hasNodes(): boolean {
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].nodes.length > 0) {
        return true;
      }
    }
    return false;
  }

  /** 只有单个非空分组时省略分组头（信息已由订阅条承载） */
  private isSingleGroup(): boolean {
    let count: number = 0;
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].nodes.length > 0) {
        count++;
      }
    }
    return count <= 1;
  }

  build() {
    Scroll() {
      ContentFrame() {
        Column({ space: 8 }) {
          this.subscriptionBar()
          this.usageCard()
          if (this.showSwitcher) {
            this.subscriptionSwitcher()
          }
          this.filterToolbar()
          if (this.showImport) {
            this.importCard()
          }
          if (this.importMessage.length > 0) {
            this.messageBar()
          }
          this.nodeList()
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 12, bottom: 180 })
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  /**
   * 订阅条 48 vp。
   *
   * 旧版把「刷新 / 全部测速 / 添加订阅」放在独立操作行（38 vp），订阅卡又单独
   * 占 67 vp，且订阅名与节点数在下方分组头再次出现 —— 这里合并为一条，
   * 刷新与添加就近绑定到订阅主体上。
   */
  @Builder
  private subscriptionBar() {
    Row({ space: 0 }) {
      Circle({ width: 7, height: 7 })
        .fill(this.nodeCount > 0 ? $r('app.color.green') : $r('app.color.amber'))
        .margin({ right: 9 })
      Text(this.subscriptionName.length > 0 ? this.subscriptionName : '未配置订阅')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text'))
        .maxLines(1)
      Text(this.subscriptionMeta())
        .fontSize(11)
        .fontColor($r('app.color.muted'))
        .maxLines(2)
        .layoutWeight(1)
        .margin({ left: 8 })
      // 订阅切换入口：≥ 2 个订阅时显示（纯文字，零缺字风险）。
      // 切换逻辑复用 Index.selectSubscriptionById：未连接只换列表，
      // 已连接则断开→重生配置→重连，与设置页「设为当前」同一语义。
      if (this.subscriptions.length > 1) {
        Text(this.showSwitcher ? '收起' : '切换')
          .fontSize(11)
          .fontColor(this.showSwitcher ? $r('app.color.green') : $r('app.color.sub'))
          .height(32)
          .padding({ left: 10, right: 10 })
          .borderRadius(8)
          .backgroundColor($r('app.color.surface2'))
          .border({ width: 1, color: this.showSwitcher ? $r('app.color.green') : $r('app.color.line_soft') })
          .margin({ left: 6 })
          .onClick(() => {
            this.showSwitcher = !this.showSwitcher;
          })
      }
      this.iconButton(IconKind.Refresh, () => {
        this.onRefresh();
      })
      this.iconButton(IconKind.Plus, () => {
        this.showImport = !this.showImport;
      }, true)
    }
    .width('100%')
    .height(48)
    .padding({ left: 12, right: 8 })
    .borderRadius(10)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
  }

  /** 订阅切换面板：列出全部订阅，当前项带「当前」徽标；点非当前项即切换 */
  @Builder
  private subscriptionSwitcher() {
    Column({ space: 0 }) {
      Row() {
        Text('切换订阅')
          .fontSize(11)
          .fontColor($r('app.color.muted'))
        Blank()
        Text('收起')
          .fontSize(11)
          .fontColor($r('app.color.green'))
          .onClick(() => {
            this.showSwitcher = false;
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 4 })

      ForEach(this.subscriptions, (item: SubscriptionProfile) => {
        Row({ space: 8 }) {
          Column({ space: 2 }) {
            Text(item.name)
              .fontSize(13)
              .fontWeight(item.active ? FontWeight.Bold : FontWeight.Normal)
              .fontColor($r('app.color.text'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(item.nodeCount + ' 节点 · ' + item.detectedFormat)
              .fontSize(10)
              .fontColor($r('app.color.muted'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          if (item.active) {
            Text('当前')
              .fontSize(10)
              .fontColor($r('app.color.green'))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(999)
              .backgroundColor($r('app.color.green_soft'))
          }
        }
        .width('100%')
        .padding(12)
        .borderRadius(8)
        .backgroundColor(item.active ? $r('app.color.surface') : Color.Transparent)
        .onClick(() => {
          if (!item.active) {
            this.onSelectSubscription(item.id);
          }
          this.showSwitcher = false;
        })
      }, (item: SubscriptionProfile) => item.id + '-' + item.active + '-' + item.nodeCount + '-' + (item.usage !== null && item.usage !== undefined ? item.usage.used : -1))
    }
    .width('100%')
    .padding({ bottom: 6 })
    .borderRadius(10)
    .backgroundColor($r('app.color.surface2'))
    .border({ width: 1, color: $r('app.color.line') })
  }

  /** 订阅元信息：节点数 · 格式（· 流量摘要）。单条呈现，不再与分组头重复。 */
  private subscriptionMeta(): string {
    let base: string;
    if (this.nodeCount <= 0) {
      base = 'Clash / Base64 / 分享链接';
    } else {
      base = this.nodeCount + ' 节点 · ' + this.subscriptionFormat();
    }
    if (this.usage !== null) {
      base += ' · ' + this.usageSummary();
    }
    return base;
  }

  /** 一行式流量摘要：有总量显示「剩 x / y」，否则显示「已用 x」 */
  private usageSummary(): string {
    const u: SubscriptionUsage | null = this.usage;
    if (u === null) {
      return '';
    }
    if (u.total <= 0) {
      return '已用 ' + Fmt.bytes(u.used);
    }
    return '剩 ' + Fmt.bytes(u.remaining) + ' / ' + Fmt.bytes(u.total);
  }

  private usageRemaining(): string {
    const u: SubscriptionUsage | null = this.usage;
    if (u === null) {
      return '—';
    }
    if (u.total <= 0) {
      return '未知';
    }
    return Fmt.bytes(u.remaining);
  }

  private usageUsedLine(): string {
    const u: SubscriptionUsage | null = this.usage;
    if (u === null) {
      return '';
    }
    if (u.total <= 0) {
      return '已用 ' + Fmt.bytes(u.used) + ' · 未提供总量';
    }
    return Fmt.bytes(u.used) + ' / ' + Fmt.bytes(u.total);
  }

  private usagePercent(): number {
    const u: SubscriptionUsage | null = this.usage;
    return u === null ? -1 : Fmt.usedPercent(u.used, u.total);
  }

  /** 剩余量低于 20% 转琥珀、低于 10% 转红，便于一眼看出快用完 */
  private usageTone(): ResourceColor {
    const pct: number = this.usagePercent();
    if (pct < 0) {
      return $r('app.color.text');
    }
    if (pct >= 80) {
      return $r('app.color.red');
    }
    if (pct >= 60) {
      return $r('app.color.amber');
    }
    return $r('app.color.green');
  }

  /**
   * 流量卡片：剩余流量 + 已用/总量 + 进度条 + 到期时间。
   * 全部数据来自订阅响应头的 subscription-userinfo，不做任何估算。
   */
  @Builder
  private usageCard() {
    Column({ space: 8 }) {
      Row() {
        Text('订阅流量')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.sub'))
        Blank()
        if (this.subscriptions.length > 0 && this.usage !== null) {
          Text(this.usageRefreshing ? '刷新中' : '刷新')
            .fontSize(11)
            .fontColor(this.usageRefreshing ? $r('app.color.muted') : $r('app.color.blue'))
            .onClick(() => {
              this.onRefreshUsage();
            })
        }
      }
      .width('100%')

      if (this.usage === null) {
        Text('该订阅未提供流量信息（服务器未返回 subscription-userinfo）')
          .fontSize(11)
          .fontColor($r('app.color.muted'))
          .width('100%')
      } else {
        Row({ space: 12 }) {
          Column({ space: 3 }) {
            Text('剩余')
              .fontSize(10)
              .fontColor($r('app.color.muted'))
            Text(this.usageRemaining())
              .fontSize(19)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.usageTone())
              .maxLines(1)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Column({ space: 3 }) {
            Text('已用 / 总量')
              .fontSize(10)
              .fontColor($r('app.color.muted'))
            Text(this.usageUsedLine())
              .fontSize(12)
              .fontColor($r('app.color.text'))
              .maxLines(1)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')

        if (this.usagePercent() >= 0) {
          Row({ space: 8 }) {
            Progress({ value: this.usagePercent(), total: 100, type: ProgressType.Linear })
              .layoutWeight(1)
              .color(this.usageTone())
              .backgroundColor($r('app.color.line_soft'))
            Text(this.usagePercent() + '%')
              .fontSize(11)
              .fontColor($r('app.color.muted'))
          }
          .width('100%')
        }

        Row({ space: 12 }) {
          Text('↑ ' + this.usageUpText())
            .fontSize(10)
            .fontColor($r('app.color.muted'))
          Text('↓ ' + this.usageDownText())
            .fontSize(10)
            .fontColor($r('app.color.muted'))
          Blank()
          Text('到期 ' + this.usageExpireText())
            .fontSize(10)
            .fontColor(this.usageExpireTone())
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(10)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
    .opacity(this.usageRefreshing ? 0.6 : 1)
  }

  private usageUpText(): string {
    const u: SubscriptionUsage | null = this.usage;
    return u === null ? '—' : Fmt.bytes(u.upload);
  }

  private usageDownText(): string {
    const u: SubscriptionUsage | null = this.usage;
    return u === null ? '—' : Fmt.bytes(u.download);
  }

  private usageExpireText(): string {
    const u: SubscriptionUsage | null = this.usage;
    return u === null ? '未提供' : Fmt.expire(u.expireMs);
  }

  private usageExpireTone(): ResourceColor {
    const u: SubscriptionUsage | null = this.usage;
    if (u === null || u.expireMs <= 0) {
      return $r('app.color.muted');
    }
    if (u.expireMs <= Date.now()) {
      return $r('app.color.red');
    }
    if (u.expireMs - Date.now() <= 3 * 86400000) {
      return $r('app.color.amber');
    }
    return $r('app.color.muted');
  }

  private subscriptionFormat(): string {
    if (this.groups.length > 0 && this.groups[0].type.length > 0) {
      const t: string = this.groups[0].type;
      if (t === 'base64-links') {
        return 'base64';
      }
      if (t === 'share-links') {
        return '分享链接';
      }
      return t;
    }
    return 'base64';
  }

  /**
   * 工具条 40 vp：搜索 + 协议筛选 + 排序分段 + 测速。
   * 注意：构件名不能叫 toolbar —— CustomComponent 已有同名方法
   * （common.d.ts 的 toolbar(value: CustomBuilder)），会编译报错。
   * 旧版搜索行占 42 vp，却只放了搜索框与一个排序按钮，右侧约 60% 是空白。
   */
  @Builder
  private filterToolbar() {
    Row({ space: 8 }) {
      Row({ space: 6 }) {
        this.icon(IconKind.Search, 14, $r('app.color.muted'))
        TextInput({ placeholder: this.nodeCount > 0 ? '搜索 ' + this.nodeCount + ' 个节点' : '搜索节点', text: this.searchText })
          .height(38)
          .fontSize(12)
          .fontColor($r('app.color.text'))
          .placeholderColor($r('app.color.muted'))
          .backgroundColor(Color.Transparent)
          .padding(0)
          .borderRadius(0)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.searchText = value;
          })
        this.protocolChip()
      }
      .height(40)
      .padding({ left: 11, right: 6 })
      .borderRadius(10)
      .backgroundColor($r('app.color.surface'))
      .border({ width: 1, color: $r('app.color.line_soft') })
      .layoutWeight(1)

      this.sortSegment()
      this.iconButton(IconKind.Speed, () => {
        if (!this.testingAll) {
          this.onTestAll();
        }
      }, false, 40, this.testingAll)
    }
    .width('100%')
  }

  /** 协议筛选块：只列当前订阅里真实存在的协议，避免出现选了必然为空的项 */
  @Builder
  private protocolChip() {
    Row({ space: 3 }) {
      Text(this.protocolLabel())
        .fontSize(11)
        .fontColor(this.protocolFilter.length > 0 ? $r('app.color.green') : $r('app.color.sub'))
      this.icon(IconKind.ChevronDown, 9, this.protocolFilter.length > 0 ? $r('app.color.green') : $r('app.color.sub'))
    }
    .height(24)
    .padding({ left: 6, right: 6 })
    .borderRadius(6)
    .backgroundColor(this.protocolFilter.length > 0 ? $r('app.color.green_soft') : $r('app.color.surface2'))
    .border({ width: 1, color: this.protocolFilter.length > 0 ? $r('app.color.green') : $r('app.color.line') })
    .onClick(() => {
      this.showProtocolMenu = !this.showProtocolMenu;
    })
  }

  private protocolLabel(): string {
    if (this.protocolFilter.length === 0) {
      return '协议';
    }
    if (this.protocolFilter.length === 1) {
      return this.protocolFilter[0].toUpperCase();
    }
    return '已筛 ' + this.protocolFilter.length;
  }

  /** 延迟 / 名称 两态分段控件，取代旧版单个「延迟 ↓」按钮 */
  @Builder
  private sortSegment() {
    Row({ space: 2 }) {
      this.segmentItem('延迟', 'latency')
      this.segmentItem('名称', 'name')
    }
    .height(40)
    .padding(3)
    .borderRadius(10)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line_soft') })
  }

  @Builder
  private segmentItem(label: string, key: SortKey) {
    Text(label)
      .fontSize(12)
      .fontWeight(this.sortKey === key ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.sortKey === key ? $r('app.color.green') : $r('app.color.muted'))
      .height(32)
      .padding({ left: 10, right: 10 })
      .borderRadius(7)
      .backgroundColor(this.sortKey === key ? $r('app.color.green_soft') : Color.Transparent)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.sortKey = key;
      })
  }

  @Builder
  private messageBar() {
    Text(this.importMessage)
      .fontSize(12)
      .fontColor(this.importMessage.indexOf('失败') >= 0 ? $r('app.color.red') : $r('app.color.green'))
      .width('100%')
      .padding(10)
      .borderRadius(8)
      .backgroundColor(this.importMessage.indexOf('失败') >= 0 ? $r('app.color.red_soft') : $r('app.color.green_soft'))
  }

  @Builder
  private importCard() {
    Column({ space: 10 }) {
      Row() {
        Text('导入配置')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
        Blank()
        Text('收起')
          .fontSize(12)
          .fontColor($r('app.color.muted'))
          .onClick(() => {
            this.showImport = false;
          })
      }
      .width('100%')

      TextInput({ placeholder: '订阅名称', text: this.importName })
        .height(40)
        .fontSize(13)
        .fontColor($r('app.color.text'))
        .placeholderColor($r('app.color.muted'))
        .backgroundColor($r('app.color.app'))
        .border({ width: 1, color: $r('app.color.line_soft') })
        .borderRadius(8)
        .onChange((value: string) => {
          this.importName = value;
        })
      TextInput({ placeholder: 'https://...', text: this.importUrl })
        .height(40)
        .fontSize(13)
        .fontColor($r('app.color.text'))
        .placeholderColor($r('app.color.muted'))
        .backgroundColor($r('app.color.app'))
        .border({ width: 1, color: $r('app.color.line_soft') })
        .borderRadius(8)
        .onChange((value: string) => {
          this.importUrl = value;
        })
      Button('从链接导入')
        .type(ButtonType.Normal)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.blue'))
        .backgroundColor($r('app.color.blue_soft'))
        .borderRadius(8)
        .height(38)
        .width('100%')
        .onClick(() => {
          this.onImportUrl(this.importName, this.importUrl);
        })

      Divider().color($r('app.color.line_soft'))

      TextInput({ placeholder: '粘贴 Clash YAML、Base64 订阅或分享链接', text: this.importText })
        .height(96)
        .fontSize(12)
        .fontColor($r('app.color.text'))
        .placeholderColor($r('app.color.muted'))
        .backgroundColor($r('app.color.app'))
        .border({ width: 1, color: $r('app.color.line_soft') })
        .borderRadius(8)
        .onChange((value: string) => {
          this.importText = value;
        })
      Button('从剪贴板内容导入')
        .type(ButtonType.Normal)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.green'))
        .backgroundColor($r('app.color.green_soft'))
        .borderRadius(8)
        .height(38)
        .width('100%')
        .onClick(() => {
          this.onImportText(this.importName, this.importText);
        })
    }
    .width('100%')
    .padding(14)
    .borderRadius(10)
    .backgroundColor($r('app.color.surface2'))
    .border({ width: 1, color: $r('app.color.line') })
  }

  @Builder
  private nodeList() {
    Column({ space: 0 }) {
      if (this.showProtocolMenu) {
        this.protocolMenu()
      }
      ForEach(this.filteredGroups(), (group: ProxyGroup) => {
        Column({ space: 0 }) {
          if (!this.isSingleGroup()) {
            this.groupHeader(group)
          }
          ForEach(group.nodes, (node: ProxyNode) => {
            this.nodeRow(node)
          }, (node: ProxyNode) => this.nodeKey(node))
        }
        .width('100%')
      }, (group: ProxyGroup) => this.groupKey(group))
      if (this.filteredCount() === 0) {
        this.emptyState()
      }
    }
    .width('100%')
  }

  private filteredCount(): number {
    const groups: ProxyGroup[] = this.filteredGroups();
    let n: number = 0;
    for (let i = 0; i < groups.length; i++) {
      n += groups[i].nodes.length;
    }
    return n;
  }

  @Builder
  private emptyState() {
    Column({ space: 6 }) {
      Text(this.nodeCount > 0 ? '没有匹配的节点' : '尚未导入订阅')
        .fontSize(13)
        .fontColor($r('app.color.sub'))
      Text(this.nodeCount > 0 ? '试试清空搜索或协议筛选' : '点击右上角 ＋ 导入订阅链接')
        .fontSize(11)
        .fontColor($r('app.color.muted'))
    }
    .width('100%')
    .padding({ top: 40, bottom: 40 })
    .justifyContent(FlexAlign.Center)
  }

  /** 协议筛选菜单：只列真实存在的协议 */
  @Builder
  private protocolMenu() {
    Column({ space: 0 }) {
      Row() {
        Text('按协议筛选')
          .fontSize(11)
          .fontColor($r('app.color.muted'))
        Blank()
        if (this.protocolFilter.length > 0) {
          Text('清空')
            .fontSize(11)
            .fontColor($r('app.color.green'))
            .onClick(() => {
              this.protocolFilter = [];
            })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 4 })

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.availableProtocols(), (proto: string) => {
          Text(proto.toUpperCase())
            .fontSize(11)
            .fontColor(this.isProtocolOn(proto) ? $r('app.color.green') : $r('app.color.sub'))
            .height(28)
            .padding({ left: 10, right: 10 })
            .margin({ right: 6, bottom: 6 })
            .borderRadius(6)
            .backgroundColor(this.isProtocolOn(proto) ? $r('app.color.green_soft') : $r('app.color.surface'))
            .border({
              width: 1,
              color: this.isProtocolOn(proto) ? $r('app.color.green') : $r('app.color.line_soft')
            })
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.toggleProtocol(proto);
            })
        }, (proto: string) => proto)
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 6 })
    }
    .width('100%')
    .margin({ bottom: 8 })
    .borderRadius(10)
    .backgroundColor($r('app.color.surface2'))
    .border({ width: 1, color: $r('app.color.line') })
  }

  /** 分组头 26 vp：地区名 + 节点数 + 最优延迟 */
  @Builder
  private groupHeader(group: ProxyGroup) {
    Row({ space: 7 }) {
      Text(group.name)
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.sub'))
      Text(group.nodes.length + ' 个节点')
        .fontSize(10)
        .fontColor($r('app.color.muted'))
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .borderRadius(5)
        .backgroundColor($r('app.color.surface2'))
      Blank()
      Text(this.groupBestLatency(group))
        .fontSize(10)
        .fontColor($r('app.color.muted'))
    }
    .width('100%')
    .height(26)
    .alignItems(VerticalAlign.Center)
  }

  /** 分组内最优延迟，帮用户跳过逐个看数字 */
  private groupBestLatency(group: ProxyGroup): string {
    let best: number = -1;
    for (let i = 0; i < group.nodes.length; i++) {
      const l: number = group.nodes[i].latency;
      if (l > 0 && (best < 0 || l < best)) {
        best = l;
      }
    }
    return best > 0 ? '最优 ' + best + ' ms' : '未测速';
  }

  private nodeKey(node: ProxyNode): string {
    // 排序/选中变化时让 key 变化，强制 ForEach 重建以反映新顺序与样式
    return this.sortKey + ':' + node.name + ':' + (node.latency > 0 ? node.latency : 0) +
      ':' + (node.name === this.selectedNode ? '1' : '0');
  }

  private groupKey(group: ProxyGroup): string {
    return this.sortKey + ':g:' + group.name + ':' + group.nodes.length;
  }

  /**
   * 节点行 44 vp，整行一个点击目标。
   *
   * 相比旧版（58 vp 两行 + 右侧「延迟」「选择」两个按钮）：
   *  - 协议移入左侧徽标（旧版画首字母，357 个节点里几乎全是 S，没有信息量）
   *  - 去掉「协议 · 分组」第二行，分组已由分组头表达
   *  - 「已选 / 选择」按钮改为 20 vp 选中勾，消除第二个点击焦点
   */
  @Builder
  private nodeRow(node: ProxyNode) {
    Row({ space: 6 }) {
      Column()
        .width(3)
        .height(20)
        .borderRadius(2)
        .backgroundColor(node.name === this.selectedNode ? $r('app.color.green') : Color.Transparent)
      Text(this.protocolAbbr(node.protocol))
        .fontSize(10)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.protocolColor(node.protocol))
        .width(26)
        .height(24)
        .borderRadius(6)
        .backgroundColor(this.protocolBackground(node.protocol))
        .textAlign(TextAlign.Center)
        .margin({ left: 5 })
      Text(node.name)
        .fontSize(13)
        .fontWeight(node.name === this.selectedNode ? FontWeight.Bold : FontWeight.Normal)
        .fontColor($r('app.color.text'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(this.latencyText(node.name))
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.latencyColor(node.name))
        .backgroundColor(this.latencyBackground(node.name))
        .height(22)
        // 58vp 装不下「测试中」三字（11vp 字号约需 33vp + 内边距），放宽到 62
        .width(62)
        .borderRadius(999)
        .textAlign(TextAlign.Center)
      Stack() {
        if (node.name === this.selectedNode) {
          this.icon(IconKind.Check, 11, $r('app.color.surface'))
        }
      }
      .width(20)
      .height(20)
      .borderRadius(10)
      .backgroundColor(node.name === this.selectedNode ? $r('app.color.green') : Color.Transparent)
      .border({
        width: node.name === this.selectedNode ? 0 : 1.5,
        color: node.name === this.selectedNode ? $r('app.color.green') : $r('app.color.line')
      })
    }
    .width('100%')
    .height(44)
    .padding({ right: 8 })
    .borderRadius(9)
    .backgroundColor(node.name === this.selectedNode ? $r('app.color.green_tint') : $r('app.color.surface'))
    .border({ width: 1, color: node.name === this.selectedNode ? $r('app.color.green') : $r('app.color.line_soft') })
    .margin({ bottom: 4 })
    .onClick(() => {
      this.onSelectNode(node.name);
    })
  }

  /** 协议两字缩写：比首字母有信息量（首字母几乎永远是 S） */
  private protocolAbbr(protocol: string): string {
    const p: string = protocol.toLowerCase();
    if (p === 'shadowsocks' || p === 'ss') {
      return 'SS';
    }
    if (p === 'vmess') {
      return 'VM';
    }
    if (p === 'vless') {
      return 'VL';
    }
    if (p === 'trojan') {
      return 'TR';
    }
    if (p === 'hysteria2' || p === 'hysteria') {
      return 'HY';
    }
    if (p === 'tuic') {
      return 'TU';
    }
    if (p === 'ssr') {
      return 'SR';
    }
    if (protocol.length >= 2) {
      return protocol.substring(0, 2).toUpperCase();
    }
    return protocol.toUpperCase();
  }

  private protocolColor(protocol: string): ResourceColor {
    const p: string = protocol.toLowerCase();
    if (p === 'vmess' || p === 'vless') {
      return $r('app.color.blue');
    }
    if (p === 'trojan' || p === 'hysteria2' || p === 'hysteria') {
      return $r('app.color.amber');
    }
    return $r('app.color.cyan');
  }

  private protocolBackground(protocol: string): ResourceColor {
    const p: string = protocol.toLowerCase();
    if (p === 'vmess' || p === 'vless') {
      return $r('app.color.blue_soft');
    }
    if (p === 'trojan' || p === 'hysteria2' || p === 'hysteria') {
      return $r('app.color.amber_soft');
    }
    return $r('app.color.cyan_soft');
  }

  private filteredGroups(): ProxyGroup[] {
    const keyword = this.searchText.trim().toLowerCase();
    const result: ProxyGroup[] = [];
    this.groups.forEach((group: ProxyGroup) => {
      const nodes = group.nodes.filter((node: ProxyNode) =>
        (keyword.length === 0 ||
          node.name.toLowerCase().indexOf(keyword) >= 0 ||
          node.protocol.toLowerCase().indexOf(keyword) >= 0) &&
          (this.protocolFilter.length === 0 || this.isProtocolOn(node.protocol)));
      if (this.sortKey === 'latency') {
        nodes.sort((a: ProxyNode, b: ProxyNode) => {
          const rankA = a.latency > 0 ? a.latency : 99999;
          const rankB = b.latency > 0 ? b.latency : 99999;
          return rankA - rankB;
        });
      } else {
        nodes.sort((a: ProxyNode, b: ProxyNode) => a.name.localeCompare(b.name));
      }
      if (nodes.length > 0) {
        result.push({ name: group.name, type: group.type, nodes: nodes });
      }
    });
    return result;
  }

  /** 当前订阅里真实存在的协议，去重后排序 */
  private availableProtocols(): string[] {
    const seen: string[] = [];
    this.groups.forEach((group: ProxyGroup) => {
      group.nodes.forEach((node: ProxyNode) => {
        const p: string = node.protocol.toLowerCase();
        if (p.length > 0 && seen.indexOf(p) < 0) {
          seen.push(p);
        }
      });
    });
    seen.sort((a: string, b: string) => a.localeCompare(b));
    return seen;
  }

  private isProtocolOn(protocol: string): boolean {
    return this.protocolFilter.indexOf(protocol.toLowerCase()) >= 0;
  }

  private toggleProtocol(protocol: string): void {
    const p: string = protocol.toLowerCase();
    const next: string[] = [];
    let removed: boolean = false;
    for (let i = 0; i < this.protocolFilter.length; i++) {
      if (this.protocolFilter[i] === p) {
        removed = true;
      } else {
        next.push(this.protocolFilter[i]);
      }
    }
    if (!removed) {
      next.push(p);
    }
    this.protocolFilter = next;
  }

  private latencyText(name: string): string {
    if (this.testingNode === name) {
      return '测试中';
    }
    for (let i = 0; i < this.groups.length; i++) {
      const nodes = this.groups[i].nodes;
      for (let j = 0; j < nodes.length; j++) {
        if (nodes[j].name === name) {
          if (nodes[j].latency < 0) {
            return '未测';
          }
          return nodes[j].latency > 0 ? nodes[j].latency + ' ms' : '超时';
        }
      }
    }
    return '-';
  }

  private latencyColor(name: string): ResourceColor {
    if (this.testingNode === name) {
      return $r('app.color.amber');
    }
    for (let i = 0; i < this.groups.length; i++) {
      const nodes = this.groups[i].nodes;
      for (let j = 0; j < nodes.length; j++) {
        if (nodes[j].name === name) {
          if (nodes[j].latency < 0) {
            return $r('app.color.sub');
          }
          return nodes[j].latency > 0 ? $r('app.color.green') : $r('app.color.red');
        }
      }
    }
    return $r('app.color.sub');
  }

  private latencyBackground(name: string): ResourceColor {
    if (this.testingNode === name) {
      return $r('app.color.amber_soft');
    }
    for (let i = 0; i < this.groups.length; i++) {
      const nodes = this.groups[i].nodes;
      for (let j = 0; j < nodes.length; j++) {
        if (nodes[j].name === name) {
          if (nodes[j].latency < 0) {
            return $r('app.color.surface2');
          }
          return nodes[j].latency > 0 ? $r('app.color.green_soft') : $r('app.color.red_soft');
        }
      }
    }
    return $r('app.color.surface');
  }

  // ===================== 图标 =====================
  // 项目未引入 media 图标资源，也从未使用 SymbolGlyph（sys.symbol 的具体名称在本
  // SDK 中无法离线校验，写错会渲染成空白方块）。因此改用纯形状绘制：
  // 必定可见、随主题变色、不引入新资源。

  @Builder
  private iconButton(kind: IconKind, onTap: () => void, primary: boolean = false,
    size: number = 32, busy: boolean = false) {
    Stack() {
      if (busy) {
        LoadingProgress()
          .width(16)
          .height(16)
          .color($r('app.color.blue'))
      } else {
        this.icon(kind, kind === IconKind.Plus ? 15 : 14,
          primary ? $r('app.color.green_btn_text') : $r('app.color.sub'))
      }
    }
    .width(size)
    .height(size)
    .borderRadius(size >= 40 ? 10 : 8)
    .backgroundColor(primary ? $r('app.color.green') : $r('app.color.surface2'))
    .border({ width: primary ? 0 : 1, color: primary ? $r('app.color.green') : $r('app.color.line_soft') })
    .margin({ left: 6 })
    .onClick(onTap)
  }

  /**
   * 图标。
   *
   * 实现取舍（两版试错后的结论）：
   *  - 不用 SymbolGlyph：sys.symbol 的具体名称在本 SDK 中无法离线校验，
   *    写错会渲染成空白方块。
   *  - 不用 Path.commands：实测其坐标按 **px** 解释而非 vp，24 单位的路径
   *    在 24vp 盒子里只画出约 1/6 大小，真机上是一团小点（已复现）。
   *  - 最终用基础组件拼形状：全部按 vp 布局，尺寸可控；刷新用系统字体
   *    字符 ↻（字体字形，必定可见且随 color 变色）。
   */
  @Builder
  private icon(kind: IconKind, size: number, color: ResourceColor) {
    if (kind === IconKind.Plus) {
      Stack() {
        Column().width(size).height(2.4).borderRadius(2).backgroundColor(color)
        Column().width(2.4).height(size).borderRadius(2).backgroundColor(color)
      }
      .width(size)
      .height(size)
    } else if (kind === IconKind.Check) {
      Stack() {
        Column()
          .width(size * 0.42)
          .height(2.2)
          .borderRadius(2)
          .backgroundColor(color)
          .rotate({ angle: 45 })
          .translate({ x: -size * 0.10, y: size * 0.06 })
        Column()
          .width(size * 0.78)
          .height(2.2)
          .borderRadius(2)
          .backgroundColor(color)
          .rotate({ angle: -45 })
          .translate({ x: size * 0.10, y: -size * 0.02 })
      }
      .width(size)
      .height(size)
    } else if (kind === IconKind.Search) {
      Stack() {
        Column()
          .width(size * 0.68)
          .height(size * 0.68)
          .borderRadius(size)
          .border({ width: 1.8, color: color })
          .translate({ x: -size * 0.10, y: -size * 0.10 })
        Column()
          .width(1.8)
          .height(size * 0.34)
          .borderRadius(2)
          .backgroundColor(color)
          .rotate({ angle: -45 })
          .translate({ x: size * 0.26, y: size * 0.26 })
      }
      .width(size)
      .height(size)
    } else if (kind === IconKind.ChevronDown) {
      Stack() {
        Column()
          .width(size * 0.62)
          .height(1.6)
          .borderRadius(2)
          .backgroundColor(color)
          .rotate({ angle: 45 })
          .translate({ x: -size * 0.17, y: size * 0.10 })
        Column()
          .width(size * 0.62)
          .height(1.6)
          .borderRadius(2)
          .backgroundColor(color)
          .rotate({ angle: -45 })
          .translate({ x: size * 0.17, y: size * 0.10 })
      }
      .width(size)
      .height(size)
    } else if (kind === IconKind.Speed) {
      Row({ space: size * 0.14 }) {
        Column().width(size * 0.20).height(size * 0.36).borderRadius(1.5).backgroundColor(color)
        Column().width(size * 0.20).height(size * 0.62).borderRadius(1.5).backgroundColor(color)
        Column().width(size * 0.20).height(size).borderRadius(1.5).backgroundColor(color)
      }
      .width(size)
      .height(size)
      .alignItems(VerticalAlign.Bottom)
      .justifyContent(FlexAlign.Center)
    } else {
      // Refresh：系统字体字形，避免自绘圆环的缺口处理
      Text('\u21bb')
        .fontSize(size * 1.25)
        .fontColor(color)
        .width(size)
        .height(size)
        .textAlign(TextAlign.Center)
    }
  }
}
