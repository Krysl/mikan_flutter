import 'dart:io';

import 'package:collection/collection.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import '../model/announcement.dart';
import '../model/bangumi.dart';
import '../model/bangumi_row.dart';
import '../model/carousel.dart';
import '../model/index.dart';
import '../model/record_item.dart';
import '../model/season.dart';
import '../model/subgroup.dart';
import '../model/user.dart';
import '../model/year_season.dart';
import 'consts.dart';

Future<Directory> _createDirIfNotExists(
  Directory folder,
  String subFolder,
) async {
  final dir = Directory(path.join(folder.path, subFolder));
  if (!dir.existsSync()) {
    await dir.create(recursive: true);
  }
  return dir;
}

class MyHive {
  const MyHive._();

  static const int _base = 1;

  static const int mikanBangumi = _base + 1;
  static const int mikanBangumiRow = mikanBangumi + 1;
  static const int mikanCarousel = mikanBangumiRow + 1;
  static const int mikanIndex = mikanCarousel + 1;
  static const int mikanUser = mikanIndex + 1;
  static const int mikanSubgroup = mikanUser + 1;
  static const int mikanSeason = mikanSubgroup + 1;
  static const int mikanYearSeason = mikanSeason + 1;
  static const int mikanRecordItem = mikanYearSeason + 1;
  static const int mikanAnnouncement = mikanRecordItem + 1;
  static const int mikanAnnouncementNode = mikanAnnouncement + 1;

  static late final Box settings;
  static late final Box db;

  static Future<void> init() async {
    late final Directory tmpDir;
    late final Directory appSupportDir;
    await Future.wait([
      getTemporaryDirectory().then((value) => tmpDir = value),
      getApplicationSupportDirectory().then((value) => appSupportDir = value),
    ]);
    filesDir = appSupportDir;
    productName = appSupportDir.parent.path.split(Platform.pathSeparator).last;
    cacheDir = Platform.isWindows
        ? Directory(path.join(tmpDir.path, productName))
        : tmpDir;

    await Future.wait([
      _createDirIfNotExists(cacheDir, 'images')
          .then((dir) => imagesDir = dir.path),
      _createDirIfNotExists(appSupportDir, 'http_cache_manager')
          .then((dir) => httpCacheDir = dir),
      _createDirIfNotExists(appSupportDir, 'fonts')
          .then((dir) => fontsDir = dir.path),
      _createDirIfNotExists(appSupportDir, 'cookies')
          .then((dir) => cookiesDir = dir.path),
    ]);

    Hive.init('${filesDir.path}${Platform.pathSeparator}hivedb');
    Hive.registerAdapter(BangumiAdapter());
    Hive.registerAdapter(BangumiRowAdapter());
    Hive.registerAdapter(CarouselAdapter());
    Hive.registerAdapter(IndexAdapter());
    Hive.registerAdapter(UserAdapter());
    Hive.registerAdapter(SubgroupAdapter());
    Hive.registerAdapter(SeasonAdapter());
    Hive.registerAdapter(YearSeasonAdapter());
    Hive.registerAdapter(RecordItemAdapter());
    Hive.registerAdapter(AnnouncementAdapter());
    Hive.registerAdapter(AnnouncementNodeAdapter());
    db = await Hive.openBox(HiveBoxKey.db);
    settings = await Hive.openBox(HiveBoxKey.settings);
    MikanUrls.baseUrl = MyHive.getMirrorUrl();
  }

  static late final Directory cacheDir;
  static late final Directory filesDir;
  static late final String productName;

  static late final String cookiesDir;
  static late final String imagesDir;
  static late final Directory httpCacheDir;
  static late final String fontsDir;

  static const int KB = 1024;
  static const int MB = 1024 * KB;
  static const int GB = 1024 * MB;

  static void setLogin(Map<String, dynamic> login) {
    db.put(HiveBoxKey.login, login);
  }

  static Future<void> removeLogin() async {
    await db.delete(HiveBoxKey.login);
  }

  static Map<String, dynamic> getLogin() {
    return db.get(
      HiveBoxKey.login,
      defaultValue: <String, dynamic>{},
    ).cast<String, dynamic>();
  }

  static Future<void> removeCookies() async {
    final Directory dir = Directory(cookiesDir);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  static Future<void> clearCache() async {
    await Future.wait(
      <Future<void>>[
        for (final FileSystemEntity f in cacheDir.listSync())
          f.delete(recursive: true),
      ],
    );
  }

  static Future<int> getCacheSize() async {
    final List<FileSystemEntity> listSync = cacheDir.listSync(recursive: true);
    int size = 0;
    for (final FileSystemEntity file in listSync) {
      size += file.statSync().size;
    }
    return size;
  }

  static Future<String> getFormatCacheSize() async {
    final int size = await getCacheSize();
    if (size >= GB) {
      return '${(size / GB).toStringAsFixed(2)} GB';
    }
    if (size >= MB) {
      return '${(size / MB).toStringAsFixed(2)} MB';
    }
    if (size >= KB) {
      return '${(size / KB).toStringAsFixed(2)} KB';
    }
    return '$size B';
  }

  static Future<void> setFontFamily(MapEntry<String, String>? font) {
    return settings.put(
      SettingsHiveKey.fontFamily,
      font == null ? null : {'name': font.key, 'fontFamily': font.value},
    );
  }

  static MapEntry<String, String>? getFontFamily() {
    final map = settings.get(SettingsHiveKey.fontFamily);
    if (map == null) {
      return null;
    }
    return MapEntry(map['name'], map['fontFamily']);
  }

  static int getColorSeed() {
    return settings.get(
      SettingsHiveKey.colorSeed,
      defaultValue: Colors.green.toARGB32(),
    );
  }

  static Future<void> setColorSeed(Color color) {
    return settings.put(SettingsHiveKey.colorSeed, color.toARGB32());
  }

  static int getCardStyle() {
    return settings.get(SettingsHiveKey.cardStyle, defaultValue: 1);
  }

  static Future<void> setCardStyle(int style) {
    return settings.put(SettingsHiveKey.cardStyle, style);
  }

  static bool dynamicColorEnabled() {
    return settings.get(
      SettingsHiveKey.dynamicColor,
      defaultValue: false,
    );
  }

  static Future<void> enableDynamicColor(bool enable) {
    return settings.put(SettingsHiveKey.dynamicColor, enable);
  }

  static ThemeMode getThemeMode() {
    final name = settings.get(SettingsHiveKey.themeMode);
    return ThemeMode.values.firstWhereOrNull((e) => e.name == name) ??
        ThemeMode.system;
  }

  static Future<void> setThemeMode(ThemeMode mode) async {
    final themeMode = getThemeMode();
    if (themeMode != mode) {
      await settings.put(SettingsHiveKey.themeMode, mode.name);
    }
  }

  static DateTimeMode getDateTimeMode() {
    final name = settings.get(SettingsHiveKey.dateTimeMode);
    return DateTimeMode.values.firstWhereOrNull((e) => e.name == name) ??
        DateTimeMode.normal;
  }

  static Future<void> setDateTimeMode(DateTimeMode mode) async {
    final dateTimeMode = getDateTimeMode();
    if (dateTimeMode != mode) {
      await settings.put(SettingsHiveKey.dateTimeMode, mode.name);
    }
  }

  static String getMirrorUrl() {
    return settings.get(
      SettingsHiveKey.mirrorUrl,
      defaultValue: MikanUrls.baseUrls.last,
    );
  }

  static Future<void> setMirrorUrl(String url) {
    return settings.put(SettingsHiveKey.mirrorUrl, url);
  }

  static TabletMode getTabletMode() {
    final mode = settings.get(
      SettingsHiveKey.tabletMode,
      defaultValue: TabletMode.auto.name,
    );
    return TabletMode.values.firstWhere((e) => e.name == mode);
  }

  static Future<void> setTabletMode(TabletMode mode) {
    return settings.put(SettingsHiveKey.tabletMode, mode.name);
  }

  static Decimal getCardRatio() {
    final value = settings.get(
      SettingsHiveKey.cardRatio,
      defaultValue: '0.9',
    );
    return Decimal.parse(value);
  }

  static Future<void> setCardRatio(Decimal ratio) {
    return settings.put(SettingsHiveKey.cardRatio, ratio.toString());
  }

  static Decimal getCardWidth() {
    final value = settings.get(
      SettingsHiveKey.cardWidth,
      defaultValue: '200.0',
    );
    return Decimal.parse(value);
  }

  static Future<void> setCardWidth(Decimal width) {
    return settings.put(SettingsHiveKey.cardWidth, width.toString());
  }
}

class HiveDBKey {
  const HiveDBKey._();

  static const String themeId = 'THEME_ID';
  static const String mikanIndex = 'MIKAN_INDEX';
  static const String mikanOva = 'MIKAN_OVA';
  static const String mikanSearch = 'MIKAN_SEARCH';
  static const String ignoreUpdateVersion = 'IGNORE_UPDATE_VERSION';
}

class HiveBoxKey {
  const HiveBoxKey._();

  static const String db = 'KEY_DB';
  static const String settings = 'KEY_SETTINGS';
  static const String login = 'KEY_LOGIN';
}

class SettingsHiveKey {
  const SettingsHiveKey._();

  static const String colorSeed = 'COLOR_SEED';
  static const String fontFamily = 'FONT_FAMILY';
  static const String themeMode = 'THEME_MODE';
  static const String mirrorUrl = 'MIRROR_URL';
  static const String cardRatio = 'CARD_RATIO';
  static const String cardWidth = 'CARD_WIDTH';
  static const String cardStyle = 'CARD_STYLE';
  static const String tabletMode = 'TABLET_MODE';
  static const String dynamicColor = 'DYNAMIC_COLOR';
  static const String dateTimeMode = 'DATETIME_MODE';
}

enum TabletMode {
  tablet('平板模式'),
  auto('自动'),
  disable('禁用'),
  ;

  const TabletMode(this.label);

  final String label;

  bool get isTablet => this == TabletMode.tablet;

  bool get isAuto => this == TabletMode.auto;

  bool get isDisable => this == TabletMode.disable;
}

enum DateTimeMode {
  normal('普通模式'),
  fromNow('距今模式');

  const DateTimeMode(this.label);
  final String label;

  bool get isNormalMode => this == DateTimeMode.normal;
  bool get isFromNowMode => this == DateTimeMode.fromNow;
}
