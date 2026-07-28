import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/engine_api.g.dart';

/// 镜头库在线更新(对齐官方桌面 controller.fetch_profiles_from_github):
/// 查 gyroflow/lens_profiles 最新 release, 比本地库新就下载 profiles.cbor.gz
/// 经 Pigeon 交给原生验证、落盘到 data_dir/lens_profiles/ 并热重载。
/// Dart 只当"下载器", 镜头的加载/搜索/匹配仍全部在原生 Rust 层。
/// 全程静默失败(离线/限流不影响使用), 24h 内最多查一次。
class LensProfileUpdater {
  LensProfileUpdater._();

  static const _lastCheckKey = 'lens_profiles_last_check_ms';
  static const _minInterval = Duration(hours: 24);
  static bool _checking = false;

  /// fire-and-forget 调用: `unawaited(LensProfileUpdater.maybeUpdate(api))`。
  static Future<void> maybeUpdate(EngineApi api) async {
    if (_checking) return;
    _checking = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_lastCheckKey) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < _minInterval.inMilliseconds) return;
      await prefs.setInt(_lastCheckKey, now);
      await _checkAndUpdate(api);
    } catch (e) {
      debugPrint('[lensUpdate] $e');
    } finally {
      _checking = false;
    }
  }

  static Future<void> _checkAndUpdate(EngineApi api) async {
    final local = await api.getLensProfileDbVersion();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final release = await _getJson(
        client,
        Uri.parse(
          'https://api.github.com/repos/gyroflow/lens_profiles/releases/latest',
        ),
      );
      final tag = (release['tag_name'] as String? ?? '')
          .replaceFirst(RegExp(r'^v'), '');
      final remote = int.tryParse(tag) ?? 0;
      if (remote <= 0 || remote <= local) return;

      String? url;
      for (final a in (release['assets'] as List? ?? const [])) {
        if (a is Map && a['name'] == 'profiles.cbor.gz') {
          url = a['browser_download_url'] as String?;
          break;
        }
      }
      if (url == null) return;

      debugPrint('[lensUpdate] v$local -> v$remote, downloading...');
      final bytes = await _getBytes(client, Uri.parse(url));
      final installed = await api.installLensProfiles(bytes);
      debugPrint('[lensUpdate] installed v$installed');
    } finally {
      client.close();
    }
  }

  static Future<Map<String, dynamic>> _getJson(
    HttpClient client,
    Uri url,
  ) async {
    final req = await client.getUrl(url);
    req.headers.set(HttpHeaders.userAgentHeader, 'runcam-gf');
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != HttpStatus.ok) {
      throw 'GET $url -> ${resp.statusCode}';
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }

  static Future<Uint8List> _getBytes(HttpClient client, Uri url) async {
    final req = await client.getUrl(url);
    req.headers.set(HttpHeaders.userAgentHeader, 'runcam-gf');
    final resp = await req.close();
    if (resp.statusCode != HttpStatus.ok) {
      throw 'GET $url -> ${resp.statusCode}';
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
