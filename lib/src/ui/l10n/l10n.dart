// 本地化运行时支持:
//  - 语言选择规则(对齐需求):手机系统为「简体中文」时显示中文,其它一切语言显示英文。
//  - 全局 [L].current:供无 BuildContext 的代码(如 EditController/状态层)取译文。
//  - BuildContext.l10n:供 Widget 取译文(随系统语言变化自动重建)。
//
// 英文译文以官方源码 Gyroflow_fork/resources/translations/zh_CN.ts 的
// <source>(英文原文)为准对齐;app 特有的状态/提示文案则自然英译。
import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

/// 全局当前译文实例。由 [MaterialApp.builder] 在每次重建时写入,
/// 故与 Flutter 实际解析出的 locale 始终一致(系统语言切换后也会更新)。
class L {
  L._();

  static AppLocalizations? _current;

  /// 当前译文。Widget 树构建完成前若被读取(理论上不会),回退英文。
  static AppLocalizations get current =>
      _current ?? lookupAppLocalizations(const Locale('en'));

  static set current(AppLocalizations value) => _current = value;
}

/// Widget 内取译文的便捷写法:`context.l10n.xxx`。
extension L10nX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this)!;
}

/// 应用支持的语言:英文 + 简体中文。
const List<Locale> kSupportedLocales = <Locale>[
  Locale('en'),
  Locale('zh'),
];

/// 是否为「简体中文」。简体 = scriptCode Hans,或地区 CN/SG,或裸 zh(默认按简体);
/// 繁体(Hant / TW / HK / MO)按需求归为「其它语言」→ 用英文。
bool _isSimplifiedChinese(Locale l) {
  if (l.languageCode != 'zh') return false;
  if (l.scriptCode == 'Hant') return false;
  if (l.scriptCode == 'Hans') return true;
  switch (l.countryCode) {
    case 'TW':
    case 'HK':
    case 'MO':
      return false;
    default:
      return true; // CN / SG / 裸 zh → 简体
  }
}

/// 语言解析:**只看首选(最高优先级)语言** —— 即手机当前选定的语言。
/// 首选为简体中文 → 中文,否则一律英文。
///
/// 注意:不能遍历整个 deviceLocales 列表去「找有没有中文」—— 手机会保留一份
/// 语言优先级列表,用户把主语言切到英文后,之前设过的中文常仍留在列表后面
/// (如 [en, zh]);若遍历命中那个 zh 就会错误地显示中文。故只取 first。
Locale resolveAppLocale(List<Locale>? deviceLocales, Iterable<Locale> _) {
  final primary = (deviceLocales != null && deviceLocales.isNotEmpty)
      ? deviceLocales.first
      : null;
  if (primary != null && _isSimplifiedChinese(primary)) {
    return const Locale('zh');
  }
  return const Locale('en');
}
