import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/machine_profile.dart';
import '../models/tunnel_config.dart';

/// Persists app settings and machine profiles using SharedPreferences.
class SettingsService extends ChangeNotifier {
  static const _keyRelayUrl = 'relay_url'; // Legacy key
  static const _keyToken = 'auth_token';     // Legacy key
  static const _keyAutoReconnect = 'auto_reconnect';
  static const _keyTunnels = 'tunnels';
  static const _keyProfiles = 'machine_profiles';
  static const _keySelectedProfile = 'selected_profile_id';
  static const _keyGitHubToken = 'github_token';

  /// Default relay for newly created profiles.
  ///
  /// The client also accepts `https://` URLs and upgrades them to WSS when it
  /// connects, but storing the WebSocket URL here makes its purpose explicit.
  static const defaultRelayUrl = 'wss://tcp-tunnel-wt89.onrender.com';
  static const renderRelayUrl = 'wss://tcp-tunnel-wt89.onrender.com';
  static const railwayRelayUrl = 'wss://tcptunnel-production.up.railway.app';
  static const defaultToken = 'changeme';

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();

    // Migrate legacy settings to machine profiles if none exist
    if (profiles.isEmpty) {
      final legacyUrl = _prefs?.getString(_keyRelayUrl) ?? defaultRelayUrl;
      final legacyToken = _prefs?.getString(_keyToken) ?? const Uuid().v4();
      final defaultProfile = MachineProfile(
        id: 'default',
        name: 'Default Machine',
        relayUrl: legacyUrl,
        token: legacyToken,
      );
      await saveProfiles([defaultProfile]);
      await setSelectedProfileId(defaultProfile.id);
    }
  }

  bool get autoReconnect => _prefs?.getBool(_keyAutoReconnect) ?? true;
  Future<void> setAutoReconnect(bool value) async {
    await _prefs?.setBool(_keyAutoReconnect, value);
    notifyListeners();
  }

  String get githubToken => _prefs?.getString(_keyGitHubToken) ?? '';
  Future<void> setGithubToken(String value) async {
    await _prefs?.setString(_keyGitHubToken, value);
    notifyListeners();
  }

  // ── Profiles ──────────────────────────────────────────────────────────────

  List<MachineProfile> get profiles {
    final json = _prefs?.getString(_keyProfiles);
    if (json == null) return [];
    try {
      final list = jsonDecode(json) as List;
      return list.map((item) => MachineProfile.fromJson(item as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveProfiles(List<MachineProfile> list) async {
    final json = jsonEncode(list.map((p) => p.toJson()).toList());
    await _prefs?.setString(_keyProfiles, json);
    notifyListeners();
  }

  String get selectedProfileId => _prefs?.getString(_keySelectedProfile) ?? 'default';

  Future<void> setSelectedProfileId(String id) async {
    await _prefs?.setString(_keySelectedProfile, id);
    notifyListeners();
  }

  MachineProfile get selectedProfile {
    final list = profiles;
    if (list.isEmpty) {
      return const MachineProfile(id: 'default', name: 'Default Machine', relayUrl: defaultRelayUrl, token: defaultToken);
    }
    return list.firstWhere(
      (p) => p.id == selectedProfileId,
      orElse: () => list.first,
    );
  }

  // ── Tunnels ───────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> get rawTunnels {
    final json = _prefs?.getString(_keyTunnels);
    if (json == null) return [];
    try {
      return (jsonDecode(json) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveTunnels(List<Map<String, dynamic>> tunnels) async {
    await _prefs?.setString(_keyTunnels, jsonEncode(tunnels));
    notifyListeners();
  }

  Future<void> saveTunnelsForProfile(String profileId, List<TunnelConfig> profileTunnels) async {
    final all = rawTunnels.map(TunnelConfig.fromJson).toList();
    all.removeWhere((t) => t.profileId == profileId);
    all.addAll(profileTunnels);
    await saveTunnels(all.map((t) => t.toJson()).toList());
  }
}
