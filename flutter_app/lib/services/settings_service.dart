import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists app settings using SharedPreferences.
class SettingsService {
  static const _keyRelayUrl = 'relay_url';
  static const _keyToken = 'auth_token';
  static const _keyAutoReconnect = 'auto_reconnect';
  static const _keyTunnels = 'tunnels';

  static const defaultRelayUrl = 'ws://localhost:8080';
  static const defaultToken = 'changeme';

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  String get relayUrl => _prefs?.getString(_keyRelayUrl) ?? defaultRelayUrl;
  String get token => _prefs?.getString(_keyToken) ?? defaultToken;
  bool get autoReconnect => _prefs?.getBool(_keyAutoReconnect) ?? true;

  Future<void> setRelayUrl(String url) async =>
      _prefs?.setString(_keyRelayUrl, url);
  Future<void> setToken(String token) async =>
      _prefs?.setString(_keyToken, token);
  Future<void> setAutoReconnect(bool value) async =>
      _prefs?.setBool(_keyAutoReconnect, value);

  List<Map<String, dynamic>> get rawTunnels {
    final json = _prefs?.getString(_keyTunnels);
    if (json == null) return [];
    return (jsonDecode(json) as List).cast<Map<String, dynamic>>();
  }

  Future<void> saveTunnels(List<Map<String, dynamic>> tunnels) async =>
      _prefs?.setString(_keyTunnels, jsonEncode(tunnels));
}
