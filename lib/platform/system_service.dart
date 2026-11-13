import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

typedef IncomingData = ({
  String? link,
  String? text,
  List<String> files,
  String? payload,
});

abstract class SystemService {
  static const _channel = MethodChannel('olako/system');

  static void Function()? _onIncoming;

  static set onIncoming(void Function()? callback) {
    _onIncoming = callback;
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler(callback == null ? null : _handle);
  }

  static Future<Object?> _handle(MethodCall call) async {
    if (call.method == 'incoming') _onIncoming?.call();
    return null;
  }

  static Future<IncomingData?> takeIncoming() async {
    if (!Platform.isAndroid) return null;
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'takeIncoming',
      );
      if (raw == null) return null;
      final files = raw['files'];
      return (
        link: raw['link'] as String?,
        text: raw['text'] as String?,
        files: files is List ? files.whereType<String>().toList() : <String>[],
        payload: raw['payload'] as String?,
      );
    } on PlatformException {
      return null;
    }
  }

  static Future<void> openUrl(String url) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('openUrl', {'url': url});
      return;
    }
    if (Platform.isWindows) {
      await Process.start('rundll32', [
        'url.dll,FileProtocolHandler',
        url,
      ], mode: ProcessStartMode.detached);
      return;
    }
    await Process.start('xdg-open', [url], mode: ProcessStartMode.detached);
  }

  static Future<void> closeApp() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('closeApp');
    } on PlatformException {
      return;
    }
  }

  static Future<void> keepAwake(bool on) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('keepAwake', {'on': on});
    } on PlatformException {
      return;
    }
  }

  static Future<String?> androidAbi() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('abi');
    } on PlatformException {
      return null;
    }
  }

  static Future<bool> installApk(String path) async {
    final status = await _channel.invokeMethod<String>('installApk', {
      'path': path,
    });
    return status == 'installing';
  }
}
