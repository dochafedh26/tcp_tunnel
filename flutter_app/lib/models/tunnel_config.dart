import 'dart:convert';

/// Represents a single tunnel forwarding rule.
/// localPort on the home machine → remoteHost:remotePort on the work network.
class TunnelConfig {
  final String id;
  final String profileId;
  final String name;
  final int localPort;
  final String remoteHost;
  final int remotePort;
  final bool enabled;

  const TunnelConfig({
    required this.id,
    required this.profileId,
    required this.name,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    this.enabled = true,
  });

  TunnelConfig copyWith({
    String? id,
    String? profileId,
    String? name,
    int? localPort,
    String? remoteHost,
    int? remotePort,
    bool? enabled,
  }) {
    return TunnelConfig(
      id: id ?? this.id,
      profileId: profileId ?? this.profileId,
      name: name ?? this.name,
      localPort: localPort ?? this.localPort,
      remoteHost: remoteHost ?? this.remoteHost,
      remotePort: remotePort ?? this.remotePort,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'profileId': profileId,
        'name': name,
        'localPort': localPort,
        'remoteHost': remoteHost,
        'remotePort': remotePort,
        'enabled': enabled,
      };

  factory TunnelConfig.fromJson(Map<String, dynamic> json) => TunnelConfig(
        id: json['id'] as String,
        profileId: json['profileId'] as String? ?? '',
        name: json['name'] as String,
        localPort: json['localPort'] as int,
        remoteHost: json['remoteHost'] as String,
        remotePort: json['remotePort'] as int,
        enabled: json['enabled'] as bool? ?? true,
      );

  String toJsonString() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is TunnelConfig && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'TunnelConfig($name: localhost:$localPort → $remoteHost:$remotePort in profile $profileId)';
}
