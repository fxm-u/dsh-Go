// 被控通道的设置页：填主机地址和令牌，打开开关。
//
// 用 dshgo://open/controlled 打开（main.dart 里 registerPageLink 注册）。
// 不放进设置索引，免得为一个实验功能改一大堆入口。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../remote/controlled_link.dart';

class ControlledLinkPage extends StatefulWidget {
  const ControlledLinkPage({super.key});

  static const pageId = 'controlled';

  @override
  State<ControlledLinkPage> createState() => _ControlledLinkPageState();
}

class _ControlledLinkPageState extends State<ControlledLinkPage> {
  static const _kEnabled = 'controlled_link.enabled';
  static const _kBase = 'controlled_link.base';
  static const _kToken = 'controlled_link.token';

  final _base = TextEditingController();
  final _token = TextEditingController();
  bool _enabled = false;
  bool _loaded = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _load();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _base.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _enabled = prefs.getBool(_kEnabled) ?? false;
      _base.text = prefs.getString(_kBase) ?? '';
      _token.text = prefs.getString(_kToken) ?? '';
      _loaded = true;
    });
  }

  Future<void> _save({required bool enabled}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, enabled);
    await prefs.setString(_kBase, _base.text.trim());
    await prefs.setString(_kToken, _token.text.trim());
    if (!mounted) return;
    setState(() => _enabled = enabled);
    if (enabled) {
      ControlledLink.instance.start(base: _base.text.trim(), token: _token.text.trim());
    } else {
      ControlledLink.instance.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ControlledLink.instance.status;
    return Scaffold(
      appBar: AppBar(title: const Text('被控通道')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('让主机（比如 DSHA 那台手机）给这台手机下指令。\n只认三种：ping / open_url / copy_text。'),
          const SizedBox(height: 16),
          TextField(
            controller: _base,
            decoration: const InputDecoration(labelText: '主机地址', hintText: 'http://192.168.1.10:33079'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            decoration: const InputDecoration(labelText: '令牌'),
            obscureText: true,
          ),
          const SizedBox(height: 20),
          SwitchListTile(
            value: _enabled,
            onChanged: _loaded ? (value) => _save(enabled: value) : null,
            title: const Text('开启被控通道'),
            subtitle: Text(_enabled ? '每 2 秒向主机要一条指令' : '关闭时不连任何地址'),
          ),
          const SizedBox(height: 12),
          Text('运行中：${status.running ? '是' : '否'}'),
          Text('最近指令：${status.lastCommand.isEmpty ? '—' : status.lastCommand}'),
          if (status.lastError.isNotEmpty) Text('最近错误：${status.lastError}'),
        ],
      ),
    );
  }
}
