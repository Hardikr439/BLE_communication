import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

// ============================================================================
// BLE SOS Service - Emergency Broadcast System
// ============================================================================
//
// This service provides emergency SOS broadcasting via BLE advertising.
//
// Features:
// - Multi-hop SOS relay (messages hop between devices)
// - GPS location encoding in compact format
// - Automatic relay of received SOS signals
// - Deduplication to prevent infinite relay loops
// - Works offline without internet connection
//
// How it works:
// 1. User triggers SOS → Device broadcasts packet with location
// 2. Nearby devices receive the broadcast → Display alert
// 3. Those devices relay the packet (with decremented TTL)
// 4. This continues until TTL reaches 0
//
// ============================================================================

/// Manufacturer ID for SOS broadcasts
const int SOS_MANUFACTURER_ID = 0x1234;

/// Protocol version for packet format
const int SOS_PROTOCOL_VERSION = 1;

/// Packet payload length
const int SOS_PAYLOAD_LENGTH = 25;

/// Maximum message length (9 characters)
const int SOS_MAX_MESSAGE_LENGTH = 9;

/// Default and maximum TTL values
const int SOS_DEFAULT_TTL = 3;
const int SOS_MAX_TTL = 10;

// ============================================================================
// Packet Event Types
// ============================================================================

enum SosPacketType {
  /// Packet was sent by this device (originated here)
  sent,

  /// Packet was received from another device
  received,

  /// Packet was relayed to other devices
  relayed,
}

// ============================================================================
// SOS Packet Model
// ============================================================================

/// Represents an SOS packet in the mesh network
///
/// Packet format (25 bytes):
/// - Version (1 byte)
/// - TTL (1 byte)
/// - Max TTL (1 byte)
/// - Message Length (1 byte)
/// - Message (9 bytes, ASCII)
/// - Latitude (3 bytes, signed int24 in millidegrees)
/// - Longitude (3 bytes, signed int24 in millidegrees)
/// - Packet ID (2 bytes, hash)
/// - Origin ID (2 bytes, hash)
/// - Relay ID (2 bytes, hash)
class SosPacket {
  final String packetId;
  final String originId;
  final String relayId;
  final int ttl;
  final int maxTtl;
  final String message;
  final int _latitudeMilli;
  final int _longitudeMilli;
  final DateTime timestamp;
  final int hopCount;
  final SosPacketType type;
  final bool isOriginLocal;

  SosPacket({
    required this.packetId,
    required this.originId,
    required this.relayId,
    required this.ttl,
    required this.maxTtl,
    required this.message,
    required double latitude,
    required double longitude,
    required this.timestamp,
    required this.hopCount,
    required this.type,
    required this.isOriginLocal,
  }) : _latitudeMilli = (latitude * 1000).round(),
       _longitudeMilli = (longitude * 1000).round();

  SosPacket._internal({
    required this.packetId,
    required this.originId,
    required this.relayId,
    required this.ttl,
    required this.maxTtl,
    required this.message,
    required int latitudeMilli,
    required int longitudeMilli,
    required this.timestamp,
    required this.hopCount,
    required this.type,
    required this.isOriginLocal,
  }) : _latitudeMilli = latitudeMilli,
       _longitudeMilli = longitudeMilli;

  /// Get latitude in degrees
  double get latitude => _latitudeMilli / 1000.0;

  /// Get longitude in degrees
  double get longitude => _longitudeMilli / 1000.0;

  /// Encode packet to bytes for BLE advertising
  Uint8List toBytes() => _SosPacketCodec.encode(this);

  /// Create a copy with modified fields
  SosPacket copyWith({
    String? relayId,
    int? ttl,
    int? hopCount,
    DateTime? timestamp,
    SosPacketType? type,
    bool? isOriginLocal,
  }) {
    return SosPacket._internal(
      packetId: packetId,
      originId: originId,
      relayId: relayId ?? this.relayId,
      ttl: ttl ?? this.ttl,
      maxTtl: maxTtl,
      message: message,
      latitudeMilli: _latitudeMilli,
      longitudeMilli: _longitudeMilli,
      timestamp: timestamp ?? this.timestamp,
      hopCount: hopCount ?? this.hopCount,
      type: type ?? this.type,
      isOriginLocal: isOriginLocal ?? this.isOriginLocal,
    );
  }

  /// Decode packet from bytes
  static SosPacket? fromBytes(Uint8List data) {
    try {
      return _SosPacketCodec.decode(data);
    } catch (e) {
      debugPrint('SOS packet decode error: $e');
      return null;
    }
  }

  /// Sanitize message to allowed characters
  static String sanitizeMessage(String input) =>
      _SosPacketCodec.sanitizeMessage(input);
}

// ============================================================================
// Packet Codec
// ============================================================================

class _SosPacketCodec {
  /// Encode packet to bytes
  static Uint8List encode(SosPacket packet) {
    final buffer = Uint8List(SOS_PAYLOAD_LENGTH);
    final data = ByteData.view(buffer.buffer);

    final sanitizedMessage = sanitizeMessage(packet.message);
    final messageBytes = ascii.encode(sanitizedMessage);

    // Header
    data.setUint8(0, SOS_PROTOCOL_VERSION);
    data.setUint8(1, packet.ttl);
    data.setUint8(2, packet.maxTtl);
    data.setUint8(3, messageBytes.length);

    // Message (9 bytes)
    for (int i = 0; i < SOS_MAX_MESSAGE_LENGTH; i++) {
      final value = i < messageBytes.length ? messageBytes[i] : 0;
      data.setUint8(4 + i, value);
    }

    // Coordinates (3 bytes each, signed int24)
    _writeInt24(data, 13, _encodeCoord(packet._latitudeMilli));
    _writeInt24(data, 16, _encodeCoord(packet._longitudeMilli));

    // IDs (2 bytes each, hashed)
    data.setUint16(19, _resolveId(packet.packetId, 'P'));
    data.setUint16(21, _resolveId(packet.originId, 'O'));
    data.setUint16(23, _resolveId(packet.relayId, 'R'));

    return buffer;
  }

  /// Decode packet from bytes
  static SosPacket? decode(Uint8List data) {
    if (data.length < SOS_PAYLOAD_LENGTH) return null;

    final version = data[0];
    if (version != SOS_PROTOCOL_VERSION) return null;

    final ttl = data[1];
    final maxTtl = data[2];
    final messageLength = data[3].clamp(0, SOS_MAX_MESSAGE_LENGTH).toInt();
    final messageBytes = data.sublist(4, 4 + messageLength);
    final message = ascii.decode(messageBytes, allowInvalid: true);

    final latitudeMilli = _readInt24(data, 13);
    final longitudeMilli = _readInt24(data, 16);

    final byteData = ByteData.view(data.buffer);
    final packetId = _expandId('P', byteData.getUint16(19));
    final originId = _expandId('O', byteData.getUint16(21));
    final relayId = _expandId('R', byteData.getUint16(23));

    final hopCount = (maxTtl - ttl).clamp(0, maxTtl);

    return SosPacket._internal(
      packetId: packetId,
      originId: originId,
      relayId: relayId,
      ttl: ttl,
      maxTtl: maxTtl,
      message: message,
      latitudeMilli: latitudeMilli,
      longitudeMilli: longitudeMilli,
      timestamp: DateTime.now(),
      hopCount: hopCount,
      type: SosPacketType.received,
      isOriginLocal: false,
    );
  }

  /// Sanitize message to ASCII uppercase
  static String sanitizeMessage(String message) {
    if (message.isEmpty) return 'HELP';
    final allowed = message
        .replaceAll(RegExp(r'[^ -~]'), '')
        .trim()
        .toUpperCase();
    if (allowed.isEmpty) return 'HELP';
    return allowed.length > SOS_MAX_MESSAGE_LENGTH
        ? allowed.substring(0, SOS_MAX_MESSAGE_LENGTH)
        : allowed;
  }

  static int _encodeCoord(int milliValue) =>
      milliValue.clamp(-8388608, 8388607);

  static void _writeInt24(ByteData data, int offset, int value) {
    final masked = value & 0xFFFFFF;
    data.setUint8(offset, (masked >> 16) & 0xFF);
    data.setUint8(offset + 1, (masked >> 8) & 0xFF);
    data.setUint8(offset + 2, masked & 0xFF);
  }

  static int _readInt24(Uint8List data, int offset) {
    final value =
        (data[offset] << 16) | (data[offset + 1] << 8) | data[offset + 2];
    return (value & 0x800000) != 0 ? value | ~0xFFFFFF : value;
  }

  static int _hash16(String value) {
    var hash = 0;
    for (final codeUnit in value.codeUnits) {
      hash = (hash * 31 + codeUnit) & 0xFFFF;
    }
    return hash;
  }

  static int _resolveId(String id, String expectedPrefix) {
    if (id.length == 5 && id.startsWith(expectedPrefix)) {
      final hexPart = id.substring(1);
      final val = int.tryParse(hexPart, radix: 16);
      if (val != null) return val;
    }
    return _hash16(id);
  }

  static String _expandId(String prefix, int hash) =>
      '$prefix${hash.toRadixString(16).padLeft(4, '0').toUpperCase()}';

  static String originCode(String rawId) => _expandId('O', _hash16(rawId));
  static String relayCode(String rawId) => _expandId('R', _hash16(rawId));
  static String packetCode(String rawId) => _expandId('P', _hash16(rawId));
}

// ============================================================================
// BLE SOS Service
// ============================================================================

/// Singleton service for BLE-based SOS emergency broadcasting
///
/// Usage:
/// ```dart
/// final sosService = BleSosService.instance;
/// await sosService.init();
///
/// // Send SOS
/// await sosService.sendSos(message: 'HELP');
///
/// // Listen for alerts
/// sosService.alertStream.listen((message) => print(message));
/// sosService.packetStream.listen((packet) => handlePacket(packet));
/// ```
class BleSosService {
  // Singleton
  BleSosService._internal();
  static final BleSosService _instance = BleSosService._internal();
  static BleSosService get instance => _instance;

  // -------------------------------------------------------------------------
  // Constants
  // -------------------------------------------------------------------------

  static const String _deviceIdKey = 'ble_sos_device_id';
  static const _uuid = Uuid();

  // -------------------------------------------------------------------------
  // State
  // -------------------------------------------------------------------------

  final FlutterBlePeripheral _blePeripheral = FlutterBlePeripheral();

  bool _isScanning = false;
  bool _isAdvertising = false;
  bool _advertisingBusy = false;
  bool _permissionsGranted = false;

  String? _deviceId;
  String? _deviceOriginCode;
  String? _deviceRelayCode;

  StreamSubscription<List<ScanResult>>? _scanSubscription;

  // Deduplication caches
  final Map<String, int> _seenPacketTtl = {};
  final Map<String, DateTime> _displayedPackets = {};
  final Map<String, DateTime> _originatedPackets = {};

  // -------------------------------------------------------------------------
  // Streams
  // -------------------------------------------------------------------------

  final _alertController = StreamController<String>.broadcast();
  final _packetController = StreamController<SosPacket>.broadcast();
  final _deviceIdController = StreamController<String>.broadcast();

  /// Stream of human-readable alert messages
  Stream<String> get alertStream => _alertController.stream;

  /// Stream of received SOS packets
  Stream<SosPacket> get packetStream => _packetController.stream;

  /// Stream of device ID updates
  Stream<String> get deviceIdStream => _deviceIdController.stream;

  /// Get current device ID
  String? get deviceId => _deviceId;

  // =========================================================================
  // Initialization
  // =========================================================================

  /// Initialize the SOS service
  Future<void> init() async {
    await _ensureDeviceId();
    if (!_permissionsGranted) {
      await _requestPermissions();
    }
    if (_permissionsGranted) {
      _startScanning();
    }
  }

  Future<void> _ensureDeviceId() async {
    if (_deviceId != null) return;

    final prefs = await SharedPreferences.getInstance();
    _deviceId = prefs.getString(_deviceIdKey);

    if (_deviceId == null) {
      _deviceId = _uuid.v4();
      await prefs.setString(_deviceIdKey, _deviceId!);
    }

    _deviceOriginCode = _SosPacketCodec.originCode(_deviceId!);
    _deviceRelayCode = _SosPacketCodec.relayCode(_deviceId!);
    _deviceIdController.add(_deviceId!);
  }

  Future<void> _requestPermissions() async {
    // Check location services
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _alertController.add(
        'Location services are disabled. Please enable them for SOS to work.',
      );
      await Geolocator.openLocationSettings();
      _permissionsGranted = false;
      return;
    }

    // Request permissions
    final permissions = [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.location,
    ];

    final statuses = await permissions.request();

    final missing = <Permission>[];
    statuses.forEach((permission, status) {
      if (permission == Permission.bluetooth) return; // Best-effort
      if (!status.isGranted && !status.isLimited) {
        missing.add(permission);
      }
    });

    _permissionsGranted = missing.isEmpty;

    if (!_permissionsGranted) {
      final labels = missing.map(_permissionLabel).join(', ');
      _alertController.add(
        'Missing permissions for SOS: $labels. Please grant in Settings.',
      );

      if (missing.any((p) => statuses[p]?.isPermanentlyDenied ?? false)) {
        await openAppSettings();
      }
    }
  }

  // =========================================================================
  // Scanning
  // =========================================================================

  void _startScanning() {
    if (_isScanning) return;
    _isScanning = true;

    FlutterBluePlus.startScan(withServices: []);

    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        final data =
            result.advertisementData.manufacturerData[SOS_MANUFACTURER_ID];
        if (data != null && data.isNotEmpty) {
          _handleIncomingPacket(data);
        }
      }
    });
  }

  // =========================================================================
  // Send SOS
  // =========================================================================

  /// Send an SOS emergency broadcast
  ///
  /// [message] - Short message (max 9 chars, will be sanitized)
  /// [ttl] - Time-To-Live / max hops (1-10, default 3)
  Future<void> sendSos({
    String message = 'HELP',
    int ttl = SOS_DEFAULT_TTL,
  }) async {
    await init();

    if (!_permissionsGranted) {
      _alertController.add('Cannot send SOS. Required permissions missing.');
      return;
    }

    // Stop any existing advertising
    if (_isAdvertising) {
      await _blePeripheral.stop();
      _isAdvertising = false;
    }

    // Get current position
    Position position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(const Duration(seconds: 10));
    } catch (e) {
      _alertController.add('Could not get location: $e');
      return;
    }

    ttl = ttl.clamp(1, SOS_MAX_TTL);
    final normalizedMessage = SosPacket.sanitizeMessage(message);

    final packet = SosPacket(
      packetId: _uuid.v4(),
      originId: _deviceId!,
      relayId: _deviceId!,
      ttl: ttl,
      maxTtl: ttl,
      message: normalizedMessage,
      latitude: double.parse(position.latitude.toStringAsFixed(6)),
      longitude: double.parse(position.longitude.toStringAsFixed(6)),
      timestamp: DateTime.now(),
      hopCount: 0,
      type: SosPacketType.sent,
      isOriginLocal: true,
    );

    _registerOriginatedPacket(packet.packetId);
    _packetController.add(packet);

    final coords =
        '${packet.latitude.toStringAsFixed(5)}, ${packet.longitude.toStringAsFixed(5)}';
    _alertController.add(
      '📡 SOS SENT! Location: $coords | Max hops: ${packet.maxTtl}',
    );

    await _broadcastPacket(packet);
  }

  // =========================================================================
  // Packet Broadcasting
  // =========================================================================

  Future<void> _broadcastPacket(SosPacket packet, {bool silent = false}) async {
    if (_advertisingBusy) {
      if (!silent) debugPrint('BLE advertising busy, skipping');
      return;
    }

    _advertisingBusy = true;

    try {
      if (_isAdvertising) {
        try {
          await _blePeripheral.stop();
          await Future.delayed(const Duration(milliseconds: 200));
        } catch (e) {
          debugPrint('Error stopping peripheral: $e');
        }
        _isAdvertising = false;
      }

      final advertiseData = AdvertiseData(
        includeDeviceName: false,
        manufacturerId: SOS_MANUFACTURER_ID,
        manufacturerData: packet.toBytes(),
      );

      await _blePeripheral.start(advertiseData: advertiseData);
      _isAdvertising = true;

      // Stop advertising after 3 seconds
      Future.delayed(const Duration(seconds: 3), () async {
        if (_isAdvertising) {
          try {
            await _blePeripheral.stop();
          } catch (e) {
            debugPrint('Error stopping peripheral: $e');
          }
          _isAdvertising = false;
        }
        _advertisingBusy = false;
      });
    } catch (e) {
      _advertisingBusy = false;
      _isAdvertising = false;
      if (!silent) {
        _alertController.add('Failed to broadcast SOS: $e');
      }
    }
  }

  // =========================================================================
  // Incoming Packet Handling
  // =========================================================================

  void _handleIncomingPacket(List<int> data) {
    final packet = SosPacket.fromBytes(Uint8List.fromList(data));
    if (packet == null) return;
    if (packet.packetId.isEmpty) return;

    // Skip our own relays
    if (_deviceRelayCode != null && packet.relayId == _deviceRelayCode) return;

    // Skip packets we originated
    if (_deviceOriginCode != null && packet.originId == _deviceOriginCode)
      return;
    if (_originatedPackets.containsKey(packet.packetId)) return;

    // Skip if we've seen this with same or higher TTL
    final cachedTtl = _seenPacketTtl[packet.packetId];
    if (cachedTtl != null && cachedTtl >= packet.ttl) return;
    _seenPacketTtl[packet.packetId] = packet.ttl;
    _trimCache();

    // Enrich packet with local info
    final enrichedPacket = packet.copyWith(
      timestamp: DateTime.now(),
      hopCount: packet.maxTtl - packet.ttl,
      isOriginLocal: packet.originId == _deviceId,
      type: SosPacketType.received,
    );

    _packetController.add(enrichedPacket);

    // Display alert (deduplicated)
    if (_markPacketDisplayed(packet.packetId)) {
      final coords =
          '${packet.latitude.toStringAsFixed(5)}, ${packet.longitude.toStringAsFixed(5)}';
      final hopInfo = packet.hopCount == 0
          ? 'Direct'
          : 'Hop ${packet.hopCount}';
      _alertController.add(
        '🆘 SOS RECEIVED from ${_shortId(packet.originId)} | $hopInfo | Location: $coords | TTL: ${packet.ttl}',
      );
    }

    // Relay if TTL > 0
    if (packet.ttl > 0) {
      _forwardPacket(packet);
    }
  }

  void _forwardPacket(SosPacket incoming) {
    if (_deviceId == null) return;
    if (_deviceOriginCode != null && incoming.originId == _deviceOriginCode)
      return;
    if (_originatedPackets.containsKey(incoming.packetId)) return;

    final nextTtl = incoming.ttl - 1;
    if (nextTtl < 0) return;

    final relayPacket = incoming.copyWith(
      relayId: _deviceId,
      ttl: nextTtl,
      hopCount: incoming.maxTtl - nextTtl,
      timestamp: DateTime.now(),
      type: SosPacketType.relayed,
      isOriginLocal: incoming.originId == _deviceId,
    );

    _packetController.add(relayPacket);
    _broadcastPacket(relayPacket, silent: true);
  }

  // =========================================================================
  // Cache Management
  // =========================================================================

  void _trimCache() {
    const maxEntries = 200;
    if (_seenPacketTtl.length <= maxEntries) return;

    final overflow = _seenPacketTtl.length - maxEntries;
    _seenPacketTtl.keys.take(overflow).toList().forEach(_seenPacketTtl.remove);

    final now = DateTime.now();
    _displayedPackets.removeWhere(
      (_, timestamp) => now.difference(timestamp) > const Duration(minutes: 5),
    );
    _originatedPackets.removeWhere(
      (_, timestamp) => now.difference(timestamp) > const Duration(minutes: 10),
    );
  }

  bool _markPacketDisplayed(String packetId) {
    final now = DateTime.now();
    final last = _displayedPackets[packetId];
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      return false;
    }
    _displayedPackets[packetId] = now;
    return true;
  }

  void _registerOriginatedPacket(String packetId) {
    final hash = _SosPacketCodec.packetCode(packetId);
    _originatedPackets[hash] = DateTime.now();
  }

  // =========================================================================
  // Utilities
  // =========================================================================

  String _shortId(String id) {
    if (id.isEmpty) return 'unknown';
    return id.substring(0, id.length < 4 ? id.length : 4).toUpperCase();
  }

  String _permissionLabel(Permission permission) {
    switch (permission) {
      case Permission.bluetoothScan:
        return 'Nearby devices (scan)';
      case Permission.bluetoothAdvertise:
        return 'Nearby devices (advertise)';
      case Permission.bluetoothConnect:
        return 'Nearby devices (connect)';
      case Permission.location:
        return 'Location';
      case Permission.bluetooth:
        return 'Bluetooth';
      default:
        return permission.toString();
    }
  }

  // =========================================================================
  // Cleanup
  // =========================================================================

  void dispose() {
    FlutterBluePlus.stopScan();
    _scanSubscription?.cancel();
    _blePeripheral.stop();
    _alertController.close();
    _packetController.close();
    _deviceIdController.close();
    _originatedPackets.clear();
  }
}
