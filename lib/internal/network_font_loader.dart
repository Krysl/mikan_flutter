import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'hive.dart';
import 'http_cache_manager.dart';

class NetworkFontLoader {
  NetworkFontLoader._();

  static late final NetworkFontLoader _fontManager;

  late final Map<String, List<String>> _loadingFonts = <String, List<String>>{};

  static void init() {
    _fontManager = NetworkFontLoader._();
  }

  static Future<void> load(
    String fontFamily,
    List<String> urls, {
    Map<String, dynamic>? headers,
    StreamController<Iterable<ProgressChunkEvent>>? chunkEvents,
    Cancelable? cancelable,
  }) async {
    await _fontManager._load(
      fontFamily,
      urls,
      headers: headers,
      chunkEvents: chunkEvents,
      cancelable: cancelable,
    );
  }

  Future<ByteData> _loadFont(
    String url, {
    String? cacheDir,
    Map<String, dynamic>? headers,
    StreamController<ProgressChunkEvent>? chunkEvents,
    Cancelable? cancelable,
  }) async {
    final File? file = await HttpCacheManager.get(
      url,
      headers: headers,
      cacheDir: cacheDir,
      chunkEvents: chunkEvents,
      cancelable: cancelable,
    );
    if (file == null) {
      return Future.error('Get font<$url> error');
    }
    final Uint8List bytes = await file.readAsBytes();
    return ByteData.view(bytes.buffer);
  }

  Future<void> _load(
    String fontFamily,
    List<String> urls, {
    Map<String, dynamic>? headers,
    StreamController<Iterable<ProgressChunkEvent>>? chunkEvents,
    Cancelable? cancelable,
  }) async {
    _loadingFonts[fontFamily] = urls;
    StreamController<ProgressChunkEvent>? eventBus;
    try {
      if (chunkEvents != null) {
        final Map<Uri, ProgressChunkEvent> combine =
            <Uri, ProgressChunkEvent>{};
        eventBus = StreamController();
        eventBus.stream.listen((event) {
          combine[event.key] = event;
          chunkEvents.sink.add(combine.values);
        });
      }
      final FontLoader fontLoader = FontLoader(fontFamily);
      for (final String url in urls) {
        final Future<ByteData> bytes = _loadFont(
          url,
          headers: headers,
          cacheDir: MyHive.fontsDir,
          chunkEvents: eventBus,
          cancelable: cancelable,
        );
        fontLoader.addFont(bytes);
      }
      await fontLoader.load();
    } finally {
      await eventBus?.close();
      _loadingFonts.remove(fontFamily);
    }
  }
}
