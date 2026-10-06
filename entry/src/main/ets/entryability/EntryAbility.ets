import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { SettingsStore } from '../services/SettingsStore';

const DOMAIN = 0x8001;
const TAG = 'LianEntry';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 主题由设置页「深色模式」开关控制（默认深色）；不再跟随系统
    try {
      const settings = new SettingsStore(this.context).load();
      this.context.getApplicationContext().setColorMode(settings.darkMode
        ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set color mode');
    }
    hilog.info(DOMAIN, TAG, 'LIAN main ability created');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'LIAN main ability destroyed');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load Index page');
        return;
      }
      hilog.info(DOMAIN, TAG, 'Index page loaded');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'LIAN window stage destroyed');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'LIAN foreground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'LIAN background');
  }
}
