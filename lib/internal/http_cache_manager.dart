import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'hive.dart';

final _pathExists = <String>{};

class HttpCacheManager {
  HttpCacheManager._();

  static late final HttpCacheManager _httpCacheManager;

  static void init() => _httpCacheManager = HttpCacheManager._();

  static final HttpClient _client = HttpClient()..autoUncompress = false;

  static final Map<String, String> _lockCache = <String, String>{};

  static final Map<String, Completer<File?>> _tasks =
      <String, Completer<File?>>{};

  static Future<File?> get(
    String url, {
    String? cacheDir,
    String? cacheKey,
    Map<String, dynamic>? headers,
    Cancelable? cancelable,

    /// chunkEvents need close by self.
    StreamController<ProgressChunkEvent>? chunkEvents,
  }) async {
    if (_tasks.containsKey(url)) {
      return _tasks[url]!.future;
    }
    final Completer<File?> completer = Completer();
    unawaited(
      _httpCacheManager
          ._(
            url,
            cacheKey: cacheKey,
            cacheDir: cacheDir,
            headers: headers,
            chunkEvents: chunkEvents,
            cancelable: cancelable,
          )
          .then(completer.complete)
          .catchError(completer.completeError)
          .whenComplete(() => _tasks.remove(url)),
    );
    _tasks[url] = completer;
    return Future.any([
      if (cancelable != null)
        cancelable._token.then((value) {
          _tasks.remove(url);
          throw value;
        }),
      completer.future,
    ]);
  }

  FutureOr<Directory> _getCacheDir([String? cacheDir]) {
    if (cacheDir == null) {
      return MyHive.httpCacheDir;
    }

    final Directory dir = Directory(cacheDir);
    if (!_pathExists.contains(cacheDir)) {
      _pathExists.add(cacheDir);
      if (!dir.existsSync()) {
        return dir.create(recursive: true);
      }
    }
    return dir;
  }

  File _childFile(Directory parentDir, String fileName) {
    return File(parentDir.path + Platform.pathSeparator + fileName);
  }

  Future<File?> _(
    String url, {
    String? cacheKey,
    String? cacheDir,
    Map<String, dynamic>? headers,
    StreamController<ProgressChunkEvent>? chunkEvents,
    Cancelable? cancelable,
  }) async {
    final Uri uri = Uri.parse(url);
    final checkResp =
        await _createNewRequest(uri, withBody: false, headers: headers);

    final rawFileKey = cacheKey ?? base64Url.encode(utf8.encode(url));
    final parentDir = await _getCacheDir(cacheDir);
    final rawFile = _childFile(parentDir, rawFileKey);

    if (rawFile.existsSync()) {
      await _justFinished(uri, rawFile, chunkEvents);
      return rawFile;
    }

    // if request error, use cache.
    if (checkResp.statusCode != HttpStatus.ok) {
      checkResp.listen(null);
      // if (rawFile.existsSync()) {
      //   await _justFinished(uri, rawFile, chunkEvents);
      //   return rawFile;
      // }
      return null;
    }

    // consuming response.
    checkResp.listen(null);

    bool isExpired = false;
    final String? cacheControl =
        checkResp.headers.value(HttpHeaders.cacheControlHeader);
    final File tempFile = _childFile(parentDir, '$rawFileKey.temp');
    if (cacheControl != null) {
      if (cacheControl.contains('no-store')) {
        // no cache, download now.
        return _nrw(uri, rawFile, tempFile, chunkEvents: chunkEvents);
      } else {
        String maxAgeKey = 'max-age';
        if (cacheControl.contains(maxAgeKey)) {
          // if exist s-maxage, override max-age, use cdn max-age
          if (cacheControl.contains('s-maxage')) {
            maxAgeKey = 's-maxage';
          }
          final String maxAgeStr = cacheControl
              .split(' ')
              .firstWhere((String str) => str.contains(maxAgeKey))
              .split('=')[1]
              .trim();
          final String seconds = RegExp(r'\d+').stringMatch(maxAgeStr)!;
          final int maxAge = int.parse(seconds) * 1000;
          final String newFlag =
              '${checkResp.headers.value(HttpHeaders.etagHeader)}_${checkResp.headers.value(HttpHeaders.lastModifiedHeader)}';
          final File lockFile = _childFile(parentDir, '$rawFileKey.lock');
          String? lockStr = _lockCache[url];
          if (lockStr == null) {
            // never empty or blank.
            if (lockFile.existsSync()) {
              lockStr = await lockFile.readAsString();
            } else {
              await lockFile.create();
            }
          }
          final int millis = DateTime.now().millisecondsSinceEpoch;
          if (lockStr != null) {
            //never empty or blank
            final List<String> split = lockStr.split('@');
            final String flag = split[1];
            final int lastReqAt = int.parse(split[0]);
            if (flag != newFlag || lastReqAt + maxAge < millis) {
              isExpired = true;
            }
          }
          final String newLockStr = <dynamic>[millis, newFlag].join('@');
          _lockCache[url] = newLockStr;
          // we don't care lock str already written in file.
          unawaited(lockFile.writeAsString(newLockStr));
        }
      }
    }
    if (!isExpired) {
      // if not expired and exist file, just return.
      if (rawFile.existsSync()) {
        await _justFinished(uri, rawFile, chunkEvents);
        return rawFile;
      }
    }

    final bool breakpointTransmission =
        checkResp.headers.value(HttpHeaders.acceptRangesHeader) == 'bytes' &&
            checkResp.contentLength > 0;
    // if not expired && is support breakpoint transmission && temp file exists
    if (!isExpired && breakpointTransmission && tempFile.existsSync()) {
      final int received = await tempFile.length();
      final HttpClientResponse resp = await _createNewRequest(
        uri,
        beforeRequest: (HttpClientRequest req) {
          req.headers.add(HttpHeaders.rangeHeader, 'bytes=$received-');
          final String? flag =
              checkResp.headers.value(HttpHeaders.etagHeader) ??
                  checkResp.headers.value(HttpHeaders.lastModifiedHeader);
          if (flag != null) {
            req.headers.add(HttpHeaders.ifRangeHeader, flag);
          }
        },
        headers: headers,
      );
      if (resp.statusCode == HttpStatus.partialContent) {
        // is ok, continue download.
        return _rw(
          uri,
          resp,
          rawFile,
          tempFile,
          chunkEvents: chunkEvents,
          received: received,
          fileMode: FileMode.append,
          cancelable: cancelable,
        );
      } else if (resp.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        // 416 Requested Range Not Satisfiable
        return _nrw(
          uri,
          rawFile,
          tempFile,
          chunkEvents: chunkEvents,
          cancelable: cancelable,
        );
      } else if (resp.statusCode == HttpStatus.ok) {
        return _rw(
          uri,
          resp,
          rawFile,
          tempFile,
          chunkEvents: chunkEvents,
          cancelable: cancelable,
        );
      } else {
        // request error.
        resp.listen(null);
        return null;
      }
    } else {
      return _nrw(
        uri,
        rawFile,
        tempFile,
        chunkEvents: chunkEvents,
        cancelable: cancelable,
      );
    }
  }

  Future<void> _justFinished(
    Uri uri,
    File rawFile,
    StreamController<ProgressChunkEvent>? chunkEvents,
  ) async {
    if (chunkEvents != null) {
      final int length = await rawFile.length();
      chunkEvents.add(
        ProgressChunkEvent(
          key: uri,
          progress: length,
          total: length,
        ),
      );
    }
  }

  Future<File?> _nrw(
    Uri uri,
    File rawFile,
    File tempFile, {
    Map<String, dynamic>? headers,
    StreamController<ProgressChunkEvent>? chunkEvents,
    Cancelable? cancelable,
  }) async {
    final HttpClientResponse resp = await _createNewRequest(
      uri,
      headers: headers,
    );
    if (resp.statusCode != HttpStatus.ok) {
      resp.listen(null);
      return null;
    }
    return _rw(
      uri,
      resp,
      rawFile,
      tempFile,
      chunkEvents: chunkEvents,
      cancelable: cancelable,
    );
  }

  Future<File> _rw(
    Uri uri,
    HttpClientResponse response,
    File rawFile,
    File tempFile, {
    StreamController<ProgressChunkEvent>? chunkEvents,
    int received = 0,
    FileMode fileMode = FileMode.write,
    Cancelable? cancelable,
  }) async {
    final Completer<File> completer = Completer<File>();
    final bool compressed = response.compressionState ==
        HttpClientResponseCompressionState.compressed;
    final int? total = compressed || response.contentLength < 0
        ? null
        : response.contentLength;
    final IOSink ioSink = tempFile.openWrite(mode: fileMode);
    late StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      (List<int> bytes) {
        if (cancelable?.isCancelled ?? false) {
          subscription.cancel();
          ioSink.close();
          return;
        }
        ioSink.add(bytes);
        received += bytes.length;
        chunkEvents?.add(
          ProgressChunkEvent(
            key: uri,
            progress: received,
            total: total,
          ),
        );
      },
      onDone: () async {
        try {
          await ioSink.close();
          Uint8List buffer = await tempFile.readAsBytes();
          if (compressed) {
            final List<int> convert = gzip.decoder.convert(buffer);
            buffer = Uint8List.fromList(convert);
            await tempFile.writeAsBytes(convert);
            chunkEvents?.add(
              ProgressChunkEvent(
                key: uri,
                progress: buffer.length,
                total: buffer.length,
              ),
            );
          }
          await tempFile.rename(rawFile.path);
          completer.complete(rawFile);
        } catch (e) {
          completer.completeError(e);
        }
      },
      onError: (dynamic err, StackTrace stackTrace) async {
        try {
          await ioSink.close();
        } finally {
          completer.completeError(err, stackTrace);
        }
      },
      cancelOnError: true,
    );
    cancelable?.onBeforeCancel(() async {
      await subscription.cancel();
      await ioSink.close();
    });
    return completer.future;
  }

  Future<HttpClientResponse> _createNewRequest(
    Uri uri, {
    Map<String, dynamic>? headers,
    bool withBody = true,
    void Function(HttpClientRequest)? beforeRequest,
  }) async {
    final HttpClientRequest request =
        await (withBody ? _client.getUrl(uri) : _client.headUrl(uri));
    headers?.forEach((String key, dynamic value) {
      request.headers.add(key, value);
    });
    beforeRequest?.call(request);
    return request.close();
  }
}

class Cancelable {
  Cancelable();

  final Completer<dynamic> _completer = Completer();

  Future<dynamic> get _token => _completer.future;

  final Set<FutureOrVoidCallback> _onBeforeCancels = <FutureOrVoidCallback>{};

  void onBeforeCancel(FutureOrVoidCallback onBeforeCancel) {
    _onBeforeCancels.add(onBeforeCancel);
  }

  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  Future<void> cancel([dynamic reason]) async {
    if (_isCancelled) {
      return;
    }
    for (final FutureOrVoidCallback f in _onBeforeCancels) {
      await f.call();
    }
    _completer.complete(reason ?? 'Cancel...');
    _isCancelled = true;
  }
}

@immutable
class ProgressChunkEvent {
  const ProgressChunkEvent({
    required this.key,
    required this.progress,
    required this.total,
  });

  final dynamic key;
  final int progress;
  final int? total;

  double? get percent =>
      total == null || total == 0 ? null : (progress / total!).clamp(0, 1);

  @override
  String toString() {
    return '{"uri": "$key","progress":$progress,"total":$total}';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProgressChunkEvent &&
          runtimeType == other.runtimeType &&
          key == other.key;

  @override
  int get hashCode => key.hashCode;
}

typedef FutureOrVoidCallback = FutureOr<void> Function();
