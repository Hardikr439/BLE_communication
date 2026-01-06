import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:geolocator/geolocator.dart';

// ============================================================================
// Constants & Configuration
// ============================================================================

/// Unique identifier for our BLE mesh network
const String MESH_SERVICE_UUID = "f47b5e2d-4a9e-4c5a-9b3f-8e1d2c3a4b5c";

/// Manufacturer ID for mesh broadcasts (custom identifier)
const int MESH_MANUFACTURER_ID = 0x8888;

/// Default Time-To-Live for mesh messages (max hops)
const int DEFAULT_TTL = 5;

/// Minimum delay before relaying a message (prevents broadcast storms)
const int MIN_RELAY_DELAY_MS = 50;

/// Maximum delay before relaying a message
const int MAX_RELAY_DELAY_MS = 200;

/// Maximum cached message IDs for deduplication
const int MESSAGE_CACHE_SIZE = 1000;

/// How long to keep message IDs in cache
const Duration MESSAGE_CACHE_EXPIRY = Duration(minutes: 5);

/// When to consider a peer stale/offline
const Duration PEER_TIMEOUT = Duration(seconds: 60);

/// Maximum message length for BLE advertising (legacy limit is 31 bytes total)
/// Structure: Type(1) + TTL(1) + MsgID(2) + SenderID(2) + Timestamp(4) + Payload
/// Available for payload: 31 - 10 = ~21 bytes, but manufacturer data overhead is ~4 bytes
const int MAX_MESSAGE_LENGTH = 15;

// ============================================================================
// Enums
// ============================================================================

/// Types of messages in the mesh network
enum MeshMessageType {
  /// Peer announcement (nickname broadcast)
  announce(0x01),

  /// Regular chat message
  message(0x04),

  /// SOS emergency message
  sos(0x10),

  /// Acknowledgment
  ack(0x20);

  final int value;
  const MeshMessageType(this.value);

  static MeshMessageType? fromValue(int value) {
    for (final type in MeshMessageType.values) {
      if (type.value == value) return type;
    }
    return null;
  }
}

// ============================================================================
// Models
// ============================================================================

/// Represents a peer in the mesh network
class MeshPeer {
  final String id;
  String nickname;
  DateTime lastSeen;
  int messagesReceived;
  int messagesRelayed;

  MeshPeer({
    required this.id,
    String? nickname,
    DateTime? lastSeen,
    this.messagesReceived = 0,
    this.messagesRelayed = 0,
  }) : nickname = nickname ?? "Peer-${id.substring(0, min(4, id.length))}",
       lastSeen = lastSeen ?? DateTime.now();

  /// Check if peer is considered online (seen recently)
  bool get isOnline => DateTime.now().difference(lastSeen) < PEER_TIMEOUT;
}

/// Represents a message in the mesh network
class MeshMessage {
  final String id;
  final String content;
  final String senderId;
  final String senderNickname;
  final DateTime timestamp;
  final MeshMessageType type;
  final bool isMe;
  final int hopCount;
  final bool wasRelayed;
  final double? latitude;
  final double? longitude;
  final String? emotion;

  MeshMessage({
    required this.id,
    required this.content,
    required this.senderId,
    required this.senderNickname,
    required this.timestamp,
    required this.type,
    required this.isMe,
    this.hopCount = 0,
    this.wasRelayed = false,
    this.latitude,
    this.longitude,
    this.emotion,
  });

  /// Parse location and emotion from message content
  /// Format: "message|lat,lon|emotion"
  factory MeshMessage.fromRawContent({
    required String id,
    required String rawContent,
    required String senderId,
    required String senderNickname,
    required DateTime timestamp,
    required MeshMessageType type,
    required bool isMe,
    int hopCount = 0,
    bool wasRelayed = false,
  }) {
    String content = rawContent;
    double? lat, lon;
    String? emotion;

    final parts = rawContent.split('|');
    if (parts.isNotEmpty) {
      content = parts[0];
      if (parts.length > 1 && parts[1].isNotEmpty) {
        final coords = parts[1].split(',');
        if (coords.length == 2) {
          lat = double.tryParse(coords[0]);
          lon = double.tryParse(coords[1]);
        }
      }
      if (parts.length > 2 && parts[2].isNotEmpty) {
        emotion = parts[2];
      }
    }

    return MeshMessage(
      id: id,
      content: content,
      senderId: senderId,
      senderNickname: senderNickname,
      timestamp: timestamp,
      type: type,
      isMe: isMe,
      hopCount: hopCount,
      wasRelayed: wasRelayed,
      latitude: lat,
      longitude: lon,
      emotion: emotion,
    );
  }
}

// ============================================================================
// BLE Mesh Service - Core Service
// ============================================================================

/// Singleton service managing BLE mesh networking
///
/// Features:
/// - Peer discovery via BLE scanning
/// - Message broadcasting via BLE advertising
/// - Multi-hop message relay with TTL
/// - Message deduplication
/// - Automatic reconnection and cleanup
class BleMeshService extends ChangeNotifier {
  // Singleton pattern
  static final BleMeshService _instance = BleMeshService._internal();
  static BleMeshService get instance => _instance;
  BleMeshService._internal();

  // -------------------------------------------------------------------------
  // State
  // -------------------------------------------------------------------------

  String? _peerId;
  String? _nickname;
  bool _isInitialized = false;
  bool _isScanning = false;
  bool _isAdvertising = false;
  bool _advertisingBusy = false;

  // Getters
  String? get peerId => _peerId;
  String? get nickname => _nickname;
  bool get isInitialized => _isInitialized;
  bool get isScanning => _isScanning;

  // -------------------------------------------------------------------------
  // BLE Components
  // -------------------------------------------------------------------------

  final FlutterBlePeripheral _blePeripheral = FlutterBlePeripheral();
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  // -------------------------------------------------------------------------
  // Data Storage
  // -------------------------------------------------------------------------

  /// Known peers in the network
  final Map<String, MeshPeer> peers = {};

  /// All received/sent messages
  final List<MeshMessage> messages = [];

  /// Processed message IDs for deduplication
  final Map<String, DateTime> _processedMessageIds = {};

  /// Last relay time per message for flood prevention
  final Map<String, DateTime> _lastRelayTime = {};

  /// Queue of messages waiting to be relayed
  final List<Uint8List> _relayQueue = [];

  // -------------------------------------------------------------------------
  // Statistics
  // -------------------------------------------------------------------------

  int totalMessagesSent = 0;
  int totalMessagesReceived = 0;
  int totalMessagesRelayed = 0;

  // -------------------------------------------------------------------------
  // Timers
  // -------------------------------------------------------------------------

  Timer? _cacheCleanupTimer;
  Timer? _relayProcessingTimer;
  Timer? _announcementTimer;

  // -------------------------------------------------------------------------
  // Streams
  // -------------------------------------------------------------------------

  final _messageController = StreamController<MeshMessage>.broadcast();
  final _statusController = StreamController<String>.broadcast();
  final _errorController = StreamController<String>.broadcast();

  Stream<MeshMessage> get messageStream => _messageController.stream;
  Stream<String> get statusStream => _statusController.stream;
  Stream<String> get errorStream => _errorController.stream;

  // =========================================================================
  // Initialization
  // =========================================================================

  /// Initialize the mesh service
  Future<void> init() async {
    if (_isInitialized) return;

    try {
      _statusController.add("Initializing...");

      // Request permissions
      await _requestPermissions();

      // Load or generate peer identity
      await _loadIdentity();

      // Start BLE scanning
      await _startScanning();

      // Start mesh timers
      _startMeshTimers();

      _isInitialized = true;
      _statusController.add("Ready (Mesh Mode)");

      // Announce presence
      await announcePresence();
    } catch (e) {
      _errorController.add("Initialization failed: $e");
      rethrow;
    }
  }

  /// Request all required permissions for BLE mesh
  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      final permissions = [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.location,
      ];

      final statuses = await permissions.request();

      final denied = statuses.entries
          .where((e) => !e.value.isGranted && !e.value.isLimited)
          .map((e) => e.key)
          .toList();

      if (denied.isNotEmpty) {
        final labels = denied.map(_permissionLabel).join(', ');
        _errorController.add("Missing permissions: $labels");
      }
    }
  }

  /// Load or generate peer identity
  Future<void> _loadIdentity() async {
    final prefs = await SharedPreferences.getInstance();

    // Load or generate peer ID
    _peerId = prefs.getString('mesh_peer_id');
    if (_peerId == null) {
      final random = Random.secure();
      final bytes = List.generate(4, (_) => random.nextInt(256));
      _peerId = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      await prefs.setString('mesh_peer_id', _peerId!);
    }

    // Load or generate nickname
    _nickname =
        prefs.getString('mesh_nickname') ??
        "User-${_peerId!.substring(0, min(4, _peerId!.length))}";
  }

  /// Update user nickname
  Future<void> setNickname(String newNickname) async {
    _nickname = newNickname;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mesh_nickname', newNickname);
    notifyListeners();

    // Announce new nickname
    await announcePresence();
  }

  // =========================================================================
  // BLE Scanning
  // =========================================================================

  Future<void> _startScanning() async {
    if (_isScanning) return;
    _isScanning = true;

    try {
      // Start continuous scanning
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 30));

      // Listen to scan results
      _scanSubscription = FlutterBluePlus.scanResults.listen(
        _processScanResults,
        onError: (error) {
          debugPrint("BLE Scan error: $error");
          _statusController.add("Scan error");
        },
      );

      // Restart scanning when it stops
      FlutterBluePlus.isScanning.listen((scanning) {
        if (!scanning && _isScanning) {
          Future.delayed(const Duration(seconds: 2), () {
            if (_isScanning) _restartScanning();
          });
        }
      });
    } catch (e) {
      debugPrint("Failed to start scanning: $e");
      _isScanning = false;
    }
  }

  Future<void> _restartScanning() async {
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 30));
    } catch (e) {
      debugPrint("Failed to restart scanning: $e");
    }
  }

  void _processScanResults(List<ScanResult> results) {
    for (final result in results) {
      final manData = result.advertisementData.manufacturerData;
      if (manData.containsKey(MESH_MANUFACTURER_ID)) {
        final data = manData[MESH_MANUFACTURER_ID];
        if (data != null && data.isNotEmpty) {
          _handleIncomingPacket(Uint8List.fromList(data));
        }
      }
    }
  }

  // =========================================================================
  // Message Handling
  // =========================================================================

  /// Process incoming mesh packet (compact format)
  /// 
  /// Packet structure:
  /// - Type: 1 byte
  /// - TTL: 1 byte
  /// - Message ID: 2 bytes (hash)
  /// - Sender ID: 2 bytes (hash)
  /// - Timestamp: 4 bytes (seconds)
  /// - Payload: remaining bytes
  void _handleIncomingPacket(Uint8List data) {
    if (data.length < 10) return; // Minimum: type + ttl + msgId(2) + senderId(2) + timestamp(4)

    try {
      int offset = 0;

      // Parse message type
      final typeValue = data[offset++];
      final type = MeshMessageType.fromValue(typeValue);
      if (type == null) return;

      // Parse TTL
      final ttl = data[offset++];

      // Parse 2-byte message ID hash
      final msgIdHash = (data[offset] << 8) | data[offset + 1];
      offset += 2;
      final messageId = 'h:$msgIdHash'; // Use hash as ID

      // Deduplication check
      if (_processedMessageIds.containsKey(messageId)) return;
      _processedMessageIds[messageId] = DateTime.now();

      // Parse 2-byte sender ID hash
      final senderIdHash = (data[offset] << 8) | data[offset + 1];
      offset += 2;
      final senderId = senderIdHash.toRadixString(16).padLeft(4, '0');

      // Skip our own messages (compare hash)
      final myIdHash = _hashTo2Bytes(_peerId!);
      if (senderIdHash == myIdHash) return;

      // Parse 4-byte timestamp (seconds)
      final timestampSecs = ByteData.sublistView(data, offset, offset + 4)
          .getUint32(0, Endian.big);
      offset += 4;
      final timestamp = DateTime.fromMillisecondsSinceEpoch(timestampSecs * 1000);

      // Calculate hop count
      final hopCount = DEFAULT_TTL - ttl;

      // Update or create peer
      if (!peers.containsKey(senderId)) {
        peers[senderId] = MeshPeer(id: senderId);
        notifyListeners();
      }
      peers[senderId]!.lastSeen = DateTime.now();
      peers[senderId]!.messagesReceived++;

      // Parse payload
      final payload = data.sublist(offset);
      final content = utf8.decode(payload, allowMalformed: true);

      // Handle based on type
      if (type == MeshMessageType.message || type == MeshMessageType.sos) {
        totalMessagesReceived++;

        final msg = MeshMessage.fromRawContent(
          id: messageId,
          rawContent: content,
          senderId: senderId,
          senderNickname: peers[senderId]?.nickname ?? "Peer-$senderId",
          timestamp: timestamp,
          type: type,
          isMe: false,
          hopCount: hopCount,
          wasRelayed: hopCount > 0,
        );

        messages.add(msg);
        _messageController.add(msg);
        notifyListeners();

        // Relay if TTL > 0
        if (ttl > 0) {
          _scheduleRelay(data, ttl, messageId);
        }
      } else if (type == MeshMessageType.announce) {
        peers[senderId]?.nickname = content;
        notifyListeners();

        // Relay announcements too
        if (ttl > 0) {
          _scheduleRelay(data, ttl, messageId);
        }
      }
    } catch (e) {
      debugPrint("Error handling packet: $e");
    }
  }

  /// Schedule a message for relay
  void _scheduleRelay(
    Uint8List originalPacket,
    int originalTtl,
    String messageId,
  ) {
    // Prevent relay spam
    if (_lastRelayTime.containsKey(messageId)) {
      final elapsed = DateTime.now().difference(_lastRelayTime[messageId]!);
      if (elapsed.inMilliseconds < MIN_RELAY_DELAY_MS) return;
    }

    // Decrement TTL
    final newTtl = originalTtl - 1;
    if (newTtl <= 0) return;

    // Create new packet with updated TTL
    final newPacket = Uint8List.fromList(originalPacket);
    newPacket[1] = newTtl;

    // Add to relay queue
    _relayQueue.add(newPacket);
    _lastRelayTime[messageId] = DateTime.now();
  }

  // =========================================================================
  // Message Sending
  // =========================================================================

  /// Send a chat message to the mesh network
  Future<void> sendMessage(String text) async {
    if (_peerId == null) {
      _errorController.add("Service not initialized");
      return;
    }

    // Get current location if available
    String locationStr = "";
    try {
      Position? position = await Geolocator.getLastKnownPosition();
      if (position == null) {
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.low,
        ).timeout(const Duration(seconds: 5));
      }
      if (position != null) {
        locationStr =
            "${position.latitude.toStringAsFixed(5)},"
            "${position.longitude.toStringAsFixed(5)}";
      }
    } catch (e) {
      debugPrint("Could not get location: $e");
    }

    // Format message with location
    final messageToSend = locationStr.isNotEmpty ? "$text|$locationStr|" : text;

    // Build packet
    final packet = _buildPacket(
      type: MeshMessageType.message,
      content: messageToSend,
    );

    // Broadcast
    await _broadcast(packet);
    totalMessagesSent++;

    // Add to local messages
    final messageId = const Uuid().v4();
    final msg = MeshMessage.fromRawContent(
      id: messageId,
      rawContent: messageToSend,
      senderId: _peerId!,
      senderNickname: "Me",
      timestamp: DateTime.now(),
      type: MeshMessageType.message,
      isMe: true,
    );
    messages.add(msg);
    _messageController.add(msg);
    notifyListeners();
  }

  /// Announce presence in the mesh network
  Future<void> announcePresence() async {
    if (_peerId == null || _nickname == null) return;

    final packet = _buildPacket(
      type: MeshMessageType.announce,
      content: _nickname!,
    );
    await _broadcast(packet);
  }

  /// Build a mesh packet with compact format
  /// 
  /// Packet structure (max 24 bytes for manufacturer data):
  /// - Type: 1 byte
  /// - TTL: 1 byte
  /// - Message ID: 2 bytes (hash of UUID)
  /// - Sender ID: 2 bytes (hash of peer ID)
  /// - Timestamp: 4 bytes (seconds since epoch, truncated)
  /// - Payload: remaining bytes (up to ~14 bytes)
  Uint8List _buildPacket({
    required MeshMessageType type,
    required String content,
    int ttl = DEFAULT_TTL,
  }) {
    final messageId = const Uuid().v4();
    
    // Hash the UUID to 2 bytes for compactness
    final msgIdHash = _hashTo2Bytes(messageId);
    
    // Hash sender ID to 2 bytes
    final senderIdHash = _hashTo2Bytes(_peerId!);
    
    // Timestamp as 4-byte seconds (good until year 2106)
    final timestampSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Truncate content if needed
    var contentBytes = utf8.encode(content);
    if (contentBytes.length > MAX_MESSAGE_LENGTH) {
      contentBytes = contentBytes.sublist(0, MAX_MESSAGE_LENGTH);
    }

    final builder = BytesBuilder();
    builder.addByte(type.value);                           // 1 byte
    builder.addByte(ttl);                                  // 1 byte
    builder.addByte((msgIdHash >> 8) & 0xFF);              // 1 byte (msg ID high)
    builder.addByte(msgIdHash & 0xFF);                     // 1 byte (msg ID low)
    builder.addByte((senderIdHash >> 8) & 0xFF);           // 1 byte (sender high)
    builder.addByte(senderIdHash & 0xFF);                  // 1 byte (sender low)
    
    // 4-byte timestamp
    final tsBytes = Uint8List(4);
    ByteData.view(tsBytes.buffer).setUint32(0, timestampSecs, Endian.big);
    builder.add(tsBytes);                                   // 4 bytes
    
    builder.add(contentBytes);                              // up to 14 bytes

    // Mark as processed using full messageId for local dedup
    _processedMessageIds[messageId] = DateTime.now();
    // Also mark the hash for incoming packet dedup
    _processedMessageIds['h:$msgIdHash'] = DateTime.now();

    return builder.toBytes();
  }
  
  /// Hash a string to a 2-byte integer for compact transmission
  int _hashTo2Bytes(String input) {
    int hash = 0;
    for (int i = 0; i < input.length; i++) {
      hash = ((hash << 5) - hash + input.codeUnitAt(i)) & 0xFFFF;
    }
    return hash;
  }

  /// Broadcast a packet via BLE advertising
  Future<void> _broadcast(Uint8List packet) async {
    if (_advertisingBusy) return;
    _advertisingBusy = true;

    try {
      // Stop existing advertising
      if (_isAdvertising) {
        await _blePeripheral.stop();
        await Future.delayed(const Duration(milliseconds: 100));
      }

      final advertiseData = AdvertiseData(
        manufacturerId: MESH_MANUFACTURER_ID,
        manufacturerData: packet,
        includeDeviceName: false,
      );

      await _blePeripheral.start(advertiseData: advertiseData);
      _isAdvertising = true;
      _statusController.add("Broadcasting...");

      // Stop after 3 seconds
      Timer(const Duration(seconds: 3), () async {
        if (_isAdvertising) {
          try {
            await _blePeripheral.stop();
            _isAdvertising = false;
            _statusController.add("Ready");
          } catch (e) {
            debugPrint("Error stopping broadcast: $e");
          }
        }
        _advertisingBusy = false;
      });
    } catch (e) {
      _advertisingBusy = false;
      _isAdvertising = false;
      _errorController.add("Broadcast failed: $e");
    }
  }

  // =========================================================================
  // Mesh Timers & Maintenance
  // =========================================================================

  void _startMeshTimers() {
    // Cache cleanup every minute
    _cacheCleanupTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _cleanupCaches();
    });

    // Relay queue processing every 100ms
    _relayProcessingTimer = Timer.periodic(const Duration(milliseconds: 100), (
      _,
    ) {
      _processRelayQueue();
    });

    // Periodic announcements every 30 seconds
    _announcementTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      announcePresence();
    });
  }

  void _cleanupCaches() {
    final now = DateTime.now();

    // Cleanup old message IDs
    _processedMessageIds.removeWhere((_, timestamp) {
      return now.difference(timestamp) > MESSAGE_CACHE_EXPIRY;
    });

    // Cleanup relay times
    _lastRelayTime.removeWhere((_, timestamp) {
      return now.difference(timestamp) > MESSAGE_CACHE_EXPIRY;
    });

    // Cleanup stale peers
    final stalePeers = peers.entries
        .where((e) => !e.value.isOnline)
        .map((e) => e.key)
        .toList();
    for (final id in stalePeers) {
      peers.remove(id);
    }

    // Cleanup old messages
    messages.removeWhere((msg) {
      return now.difference(msg.timestamp) > MESSAGE_CACHE_EXPIRY;
    });

    // Limit cache size
    if (_processedMessageIds.length > MESSAGE_CACHE_SIZE) {
      final sorted = _processedMessageIds.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      final toRemove = sorted.take(
        _processedMessageIds.length - MESSAGE_CACHE_SIZE,
      );
      for (final entry in toRemove) {
        _processedMessageIds.remove(entry.key);
      }
    }

    if (stalePeers.isNotEmpty || messages.isEmpty) {
      notifyListeners();
    }
  }

  Future<void> _processRelayQueue() async {
    if (_relayQueue.isEmpty || _isAdvertising) return;

    final packet = _relayQueue.removeAt(0);

    // Random delay to prevent broadcast storms
    final random = Random();
    final delay =
        MIN_RELAY_DELAY_MS +
        random.nextInt(MAX_RELAY_DELAY_MS - MIN_RELAY_DELAY_MS);
    await Future.delayed(Duration(milliseconds: delay));

    await _broadcast(packet);
    totalMessagesRelayed++;
  }

  // =========================================================================
  // Utilities
  // =========================================================================

  Uint8List _hexToBytes(String hex) {
    var h = hex;
    if (h.length % 2 != 0) h = '0$h';
    final bytes = Uint8List(h.length ~/ 2);
    for (int i = 0; i < h.length; i += 2) {
      bytes[i ~/ 2] = int.parse(h.substring(i, i + 2), radix: 16);
    }
    return bytes;
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

  /// Get mesh network statistics
  Map<String, dynamic> getStats() {
    return {
      'peerId': _peerId,
      'nickname': _nickname,
      'activePeers': peers.values.where((p) => p.isOnline).length,
      'totalPeers': peers.length,
      'totalMessages': messages.length,
      'messagesSent': totalMessagesSent,
      'messagesReceived': totalMessagesReceived,
      'messagesRelayed': totalMessagesRelayed,
      'cacheSize': _processedMessageIds.length,
      'queuedRelays': _relayQueue.length,
    };
  }

  // =========================================================================
  // Cleanup
  // =========================================================================

  /// Disconnect and cleanup resources
  Future<void> dispose() async {
    _isScanning = false;
    _isInitialized = false;

    _cacheCleanupTimer?.cancel();
    _relayProcessingTimer?.cancel();
    _announcementTimer?.cancel();
    _scanSubscription?.cancel();

    _relayQueue.clear();

    try {
      await _blePeripheral.stop();
      await FlutterBluePlus.stopScan();
    } catch (e) {
      debugPrint("Error during cleanup: $e");
    }

    _messageController.close();
    _statusController.close();
    _errorController.close();
  }
}
