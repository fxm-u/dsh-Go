// 被控通道：让一台「主机」能对这台手机下指令。
//
// 和 remote/relay 的方向正好相反：relay 是这台手机连到别人；
// 这里是由别人（主机）连到这台手机 —— 手机主动长轮询主机的收件箱，
// 拿到指令就执行，再把结果回报过去。
//
// 只跑白名单指令：ping / open_url / copy_text。
// 不新增依赖（只用 http + flutter/services），所以不用改 pubspec。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// 一条来自主机的指令。
class ControlledCommand {
  const ControlledCommand({required this.id, required this.cmd, this.args = const {}});

  factory ControlledCommand.fromJson(Map<String, Object?> json) => ControlledCommand(
    id: '${json['id'] ?? ''}',
    cmd: '${json['cmd'] ?? ''}',
    args: (json['args'] as Map?)?.cast<String, Object?>() ?? const {},
  );

  final String id;
  final String cmd;
  final Map<String, Object?> args;
}

class ControlledLinkStatus {
  const ControlledLinkStatus({this.running = false, this.lastError = '', this.lastCommand = '', this.lastAckAt = 0});

  final bool running;
  final String lastError;
  final String lastCommand;
  final int lastAckAt;
}

/// 被控通道服务。默认不启动；只有 prefs 里显式打开才会连主机。
class ControlledLink {
  ControlledLink._();

  static final ControlledLink instance = ControlledLink._();

  static const _kEnabled = 'controlled_link.enabled';
  static const _kBase = 'controlled_link.base';
  static const _kToken = 'controlled_link.token';
  static const _pollGap = Duration(seconds: 2);
  static const _maxBackoff = Duration(seconds: 30);

  http.Client _client = http.Client();
  Timer? _timer;
  bool _busy = false;
  int _failures = 0;

  ControlledLinkStatus get status => _status;
  ControlledLinkStatus _status = const ControlledLinkStatus();

  Future<void> startFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kEnabled) != true) return;
    final base = (prefs.getString(_kBase) ?? '').trim();
    final token = (prefs.getString(_kToken) ?? '').trim();
    if (base.isEmpty || token.isEmpty) return;
    start(base: base, token: token);
  }

  void start({required String base, required String token}) {
    stop();
    _base = base.replaceAll(RegExp(r'/+$'), '');
    _token = token;
    _failures = 0;
    _status = const ControlledLinkStatus(running: true);
    _schedule(Duration.zero);
  }

  String _base = '';
  String _token = '';

  void stop() {
    _timer?.cancel();
    _timer = null;
    _busy = false;
    _status = ControlledLinkStatus(running: false, lastCommand: _status.lastCommand, lastAckAt: _status.lastAckAt);
  }

  void _schedule(Duration gap) {
    _timer?.cancel();
    _timer = Timer(gap, _tick);
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final tick = await _pollOnce();
      _failures = 0;
      _schedule(tick ? Duration.zero : _pollGap);
    } catch (error) {
      _failures += 1;
      _status = ControlledLinkStatus(running: true, lastError: '$error', lastCommand: _status.lastCommand, lastAckAt: _status.lastAckAt);
      final seconds = (2 * _failures).clamp(_pollGap.inSeconds, _maxBackoff.inSeconds);
      final backoff = Duration(seconds: seconds);
      _schedule(backoff);
    } finally {
      _busy = false;
    }
  }

  /// 拉一条指令；执行并回报。返回 true 表示「刚干过活」，可以立刻再拉一次。
  Future<bool> _pollOnce() async {
    final res = await _client
        .get(Uri.parse('$_base/dshgo/next'), headers: {'Authorization': 'Bearer $_token'})
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw StateError('主机返回 ${res.statusCode}');
    final body = jsonDecode(res.body);
    if (body is! Map || body['cmd'] == null) return false;
    final command = ControlledCommand.fromJson(body.cast<String, Object?>());
    final result = await _run(command);
    await _ack(command.id, result);
    _status = ControlledLinkStatus(
      running: true,
      lastCommand: command.cmd,
      lastAckAt: DateTime.now().millisecondsSinceEpoch,
    );
    return true;
  }

  /// 白名单：只认这三种，别的一律拒绝并回报。
  Future<String> _run(ControlledCommand command) async {
    switch (command.cmd) {
      case 'ping':
        return 'pong';
      case 'open_url':
        final url = '${command.args['url'] ?? ''}';
        if (url.isEmpty) return 'error: 缺 url';
        final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        return ok ? 'opened' : 'error: 系统拒绝打开';
      case 'copy_text':
        final text = '${command.args['text'] ?? ''}';
        if (text.isEmpty) return 'error: 缺 text';
        await Clipboard.setData(ClipboardData(text: text));
        return 'copied ${text.length}';
      default:
        return 'error: 未知指令 ${command.cmd}';
    }
  }

  Future<void> _ack(String id, String result) async {
    if (id.isEmpty) return;
    await _client
        .post(
          Uri.parse('$_base/dshgo/ack'),
          headers: {'Authorization': 'Bearer $_token', 'content-type': 'application/json'},
          body: jsonEncode({'id': id, 'ok': !result.startsWith('error'), 'result': result}),
        )
        .timeout(const Duration(seconds: 10));
  }
}
