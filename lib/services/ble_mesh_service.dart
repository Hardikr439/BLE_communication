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
/// Structure: Type(1) + TTL(1) + MsgID(2) + SenderID(2) + Timestamp(4) + Lat(4) + Lon(4) + Payload
/// Header = 18 bytes, manufacturer data overhead = ~4 bytes
/// Available for payload: 31 - 18 - 4 = ~9 bytes
const int MAX_MESSAGE_LENGTH = 9;

// ============================================================================
// Enums
// ============================================================================

/// Types of messages in the mesh network
enum MeshMessageType {
  /// Peer announcement (nickname + friend code broadcast)
  announce(0x01),

  /// Friend request (when someone adds you)
  friendRequest(0x02),

  /// Regular chat message (broadcast)
  message(0x04),

  /// Direct message (to specific friend)
  direct(0x08),

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
  final String? targetId; // For direct messages

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
    this.targetId,
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

  /// Peer ID to Friend Code mapping (discovered via announcements)
  final Map<String, String> _peerFriendCodes = {};

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
  final _directMessageController = StreamController<MeshMessage>.broadcast();
  final _peerDiscoveryController = StreamController<MeshPeer>.broadcast();
  final _friendCodeDiscoveryController =
      StreamController<MapEntry<String, String>>.broadcast();
  final _friendRequestController =
      StreamController<MapEntry<String, String>>.broadcast();
  final _statusController = StreamController<String>.broadcast();
  final _errorController = StreamController<String>.broadcast();

  Stream<MeshMessage> get messageStream => _messageController.stream;
  Stream<MeshMessage> get directMessageStream =>
      _directMessageController.stream;
  Stream<MeshPeer> get peerDiscoveryStream => _peerDiscoveryController.stream;

  /// Stream of (peerId, friendCode) when a peer announces their friend code
  Stream<MapEntry<String, String>> get friendCodeDiscoveryStream =>
      _friendCodeDiscoveryController.stream;

  /// Stream of (nickname, friendCode) when someone sends us a friend request
  Stream<MapEntry<String, String>> get friendRequestStream =>
      _friendRequestController.stream;
  Stream<String> get statusStream => _statusController.stream;
  Stream<String> get errorStream => _errorController.stream;

  /// Get friend code for a peer (if discovered via announcement)
  String? getFriendCodeForPeer(String peerId) => _peerFriendCodes[peerId];

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
  /// Packet structures:
  ///
  /// Broadcast (message/sos/announce):
  /// - Type: 1 byte
  /// - TTL: 1 byte
  /// - Message ID: 2 bytes (hash)
  /// - Sender ID: 2 bytes (hash)
  /// - Timestamp: 4 bytes (seconds)
  /// - Latitude: 4 bytes (float32)
  /// - Longitude: 4 bytes (float32)
  /// - Payload: remaining bytes
  ///
  /// Direct message:
  /// - Type: 1 byte (0x08)
  /// - TTL: 1 byte
  /// - Message ID: 2 bytes (hash)
  /// - Sender ID: 2 bytes (hash)
  /// - Target ID: 2 bytes (hash of friend code)
  /// - Timestamp: 4 bytes (seconds)
  /// - Payload: remaining bytes
  void _handleIncomingPacket(Uint8List data) {
    if (data.length < 12) return; // Minimum header size

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

      // Handle direct messages and friend requests (same packet format)
      if (type == MeshMessageType.direct ||
          type == MeshMessageType.friendRequest) {
        _handleDirectPacket(data, offset, messageId, senderId, ttl, type);
        return;
      }

      // Parse 4-byte timestamp (seconds)
      final timestampSecs = ByteData.sublistView(
        data,
        offset,
        offset + 4,
      ).getUint32(0, Endian.big);
      offset += 4;
      final timestamp = DateTime.fromMillisecondsSinceEpoch(
        timestampSecs * 1000,
      );

      // Parse 4-byte latitude (float32)
      final latFloat = ByteData.sublistView(
        data,
        offset,
        offset + 4,
      ).getFloat32(0, Endian.big);
      offset += 4;
      final double? latitude = latFloat.isNaN ? null : latFloat;

      // Parse 4-byte longitude (float32)
      final lonFloat = ByteData.sublistView(
        data,
        offset,
        offset + 4,
      ).getFloat32(0, Endian.big);
      offset += 4;
      final double? longitude = lonFloat.isNaN ? null : lonFloat;

      // Calculate hop count
      final hopCount = DEFAULT_TTL - ttl;

      // Update or create peer and emit discovery event
      final isNewPeer = !peers.containsKey(senderId);
      if (isNewPeer) {
        peers[senderId] = MeshPeer(id: senderId);
      }
      peers[senderId]!.lastSeen = DateTime.now();
      peers[senderId]!.messagesReceived++;

      // Emit peer discovery for friend status updates
      _peerDiscoveryController.add(peers[senderId]!);

      if (isNewPeer) {
        notifyListeners();
      }

      // Parse payload (text content only, coordinates are in header)
      final payload = data.sublist(offset);
      final content = utf8.decode(payload, allowMalformed: true);

      // Handle based on type
      if (type == MeshMessageType.message || type == MeshMessageType.sos) {
        totalMessagesReceived++;

        final msg = MeshMessage(
          id: messageId,
          content: content,
          senderId: senderId,
          senderNickname: peers[senderId]?.nickname ?? "Peer-$senderId",
          timestamp: timestamp,
          type: type,
          isMe: false,
          hopCount: hopCount,
          wasRelayed: hopCount > 0,
          latitude: latitude,
          longitude: longitude,
        );

        messages.add(msg);
        _messageController.add(msg);
        notifyListeners();

        // Relay if TTL > 0
        if (ttl > 0) {
          _scheduleRelay(data, ttl, messageId);
        }
      } else if (type == MeshMessageType.announce) {
        // Parse announcement: "nickname|friendcode"
        String nickname = content;
        String? friendCode;

        if (content.contains('|')) {
          final parts = content.split('|');
          nickname = parts[0];
          if (parts.length > 1) {
            friendCode = parts[1];
          }
        }

        // Update peer info
        final peer = peers[senderId];
        if (peer != null) {
          peer.nickname = nickname;
          if (friendCode != null) {
            // Store friend code in a field we can use for matching
            _peerFriendCodes[senderId] = friendCode;
          }
        }

        // Emit peer discovery with friend code info
        if (friendCode != null) {
          _friendCodeDiscoveryController.add(MapEntry(senderId, friendCode));
        }

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

  /// Handle incoming direct message or friend request packet
  ///
  /// Direct messages are relayed through the mesh but only processed
  /// by the target recipient (compared via hash)
  void _handleDirectPacket(
    Uint8List data,
    int offset,
    String messageId,
    String senderId,
    int ttl,
    MeshMessageType type,
  ) {
    try {
      // Parse 2-byte target ID hash
      final targetIdHash = (data[offset] << 8) | data[offset + 1];
      offset += 2;

      // Parse 4-byte timestamp (seconds)
      final timestampSecs = ByteData.sublistView(
        data,
        offset,
        offset + 4,
      ).getUint32(0, Endian.big);
      offset += 4;
      final timestamp = DateTime.fromMillisecondsSinceEpoch(
        timestampSecs * 1000,
      );

      // Parse payload
      final payload = data.sublist(offset);
      final content = utf8.decode(payload, allowMalformed: true);

      // Calculate hop count
      final hopCount = DEFAULT_TTL - ttl;

      // Update or create peer
      final isNewPeer = !peers.containsKey(senderId);
      if (isNewPeer) {
        peers[senderId] = MeshPeer(id: senderId);
      }
      peers[senderId]!.lastSeen = DateTime.now();
      peers[senderId]!.messagesReceived++;
      _peerDiscoveryController.add(peers[senderId]!);

      if (isNewPeer) {
        notifyListeners();
      }

      // Check if this message is for us
      final myFriendCodeHash = _hashTo2Bytes(_generateFriendCode(_peerId!));
      final isForMe = targetIdHash == myFriendCodeHash;

      if (isForMe) {
        if (type == MeshMessageType.friendRequest) {
          // Parse friend request: "nickname|friendCode"
          String senderNickname = content;
          String? senderFriendCode;

          if (content.contains('|')) {
            final parts = content.split('|');
            senderNickname = parts[0];
            if (parts.length > 1) {
              senderFriendCode = parts[1];
            }
          }

          // Emit friend request event for auto-add
          if (senderFriendCode != null) {
            _friendRequestController.add(
              MapEntry(senderNickname, senderFriendCode),
            );

            // Also store this peer's friend code
            _peerFriendCodes[senderId] = senderFriendCode;
            peers[senderId]?.nickname = senderNickname;
          }
        } else {
          // Regular direct message
          totalMessagesReceived++;

          final msg = MeshMessage(
            id: messageId,
            content: content,
            senderId: senderId,
            senderNickname: peers[senderId]?.nickname ?? "Peer-$senderId",
            timestamp: timestamp,
            type: MeshMessageType.direct,
            isMe: false,
            hopCount: hopCount,
            wasRelayed: hopCount > 0,
            targetId: _generateFriendCode(_peerId!),
          );

          // Add to direct message stream for FriendService to handle
          _directMessageController.add(msg);
        }
        notifyListeners();
      }

      // Always relay direct messages and friend requests (even if not for us)
      if (ttl > 0) {
        _scheduleRelay(data, ttl, messageId);
      }
    } catch (e) {
      debugPrint("Error handling direct packet: $e");
    }
  }

  /// Generate friend code from peer ID (same algorithm as FriendService)
  String _generateFriendCode(String peerId) {
    // Use first 3 chars of hex hash + last 3 digits
    final hash = _hashTo2Bytes(
      peerId,
    ).toRadixString(16).padLeft(4, '0').toUpperCase();
    return '${hash.substring(0, 3)}-${hash.substring(1, 4)}';
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

    // Get current location if available (binary encoding in packet header)
    double? latitude;
    double? longitude;
    try {
      Position? position = await Geolocator.getLastKnownPosition();
      if (position == null) {
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.low,
        ).timeout(const Duration(seconds: 5));
      }
      if (position != null) {
        latitude = position.latitude;
        longitude = position.longitude;
      }
    } catch (e) {
      debugPrint("Could not get location: $e");
    }

    // Build packet with binary coordinates (not in text payload)
    final packet = _buildPacket(
      type: MeshMessageType.message,
      content: text,
      latitude: latitude,
      longitude: longitude,
    );

    // Broadcast
    await _broadcast(packet);
    totalMessagesSent++;

    // Add to local messages
    final messageId = const Uuid().v4();
    final msg = MeshMessage(
      id: messageId,
      content: text,
      senderId: _peerId!,
      senderNickname: "Me",
      timestamp: DateTime.now(),
      type: MeshMessageType.message,
      isMe: true,
      latitude: latitude,
      longitude: longitude,
    );
    messages.add(msg);
    _messageController.add(msg);
    notifyListeners();
  }

  /// Send a direct message to a specific friend
  ///
  /// The targetFriendCode is included in the packet so only the target
  /// can read it (though others will relay it)
  Future<void> sendDirectMessage(
    String text, {
    required String targetFriendCode,
  }) async {
    if (_peerId == null) {
      _errorController.add("Service not initialized");
      return;
    }

    // Build packet with target ID
    final packet = _buildDirectPacket(
      type: MeshMessageType.direct,
      content: text,
      targetFriendCode: targetFriendCode,
    );

    // Broadcast (mesh will relay, but only target processes)
    await _broadcast(packet);
    totalMessagesSent++;
    notifyListeners();
  }

  /// Build a direct message packet
  ///
  /// Packet structure (compact, for direct messages):
  /// - Type: 1 byte (0x08 for direct)
  /// - TTL: 1 byte
  /// - Message ID: 2 bytes (hash)
  /// - Sender ID: 2 bytes (hash)
  /// - Target ID: 2 bytes (hash of friend code)
  /// - Timestamp: 4 bytes
  /// - Payload: remaining bytes
  Uint8List _buildDirectPacket({
    required MeshMessageType type,
    required String content,
    required String targetFriendCode,
    int ttl = DEFAULT_TTL,
  }) {
    final messageId = const Uuid().v4();

    final msgIdHash = _hashTo2Bytes(messageId);
    final senderIdHash = _hashTo2Bytes(_peerId!);
    final targetIdHash = _hashTo2Bytes(targetFriendCode);
    final timestampSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // More space for text since no lat/lon
    var contentBytes = utf8.encode(content);
    if (contentBytes.length > 17) {
      // 31 - 14 (header) = 17 bytes for payload
      contentBytes = contentBytes.sublist(0, 17);
    }

    final builder = BytesBuilder();
    builder.addByte(type.value); // 1 byte
    builder.addByte(ttl); // 1 byte
    builder.addByte((msgIdHash >> 8) & 0xFF); // 1 byte
    builder.addByte(msgIdHash & 0xFF); // 1 byte
    builder.addByte((senderIdHash >> 8) & 0xFF); // 1 byte
    builder.addByte(senderIdHash & 0xFF); // 1 byte
    builder.addByte((targetIdHash >> 8) & 0xFF); // 1 byte (target high)
    builder.addByte(targetIdHash & 0xFF); // 1 byte (target low)

    // 4-byte timestamp
    final tsBytes = Uint8List(4);
    ByteData.view(tsBytes.buffer).setUint32(0, timestampSecs, Endian.big);
    builder.add(tsBytes); // 4 bytes

    builder.add(contentBytes); // up to 17 bytes

    // Mark as processed
    _processedMessageIds[messageId] = DateTime.now();
    _processedMessageIds['h:$msgIdHash'] = DateTime.now();

    return builder.toBytes();
  }

  /// Announce presence in the mesh network
  /// Includes friend code so others can identify us
  Future<void> announcePresence() async {
    if (_peerId == null || _nickname == null) return;

    // Include friend code in announcement: "nickname|friendcode"
    final friendCode = _generateFriendCode(_peerId!);
    final content = '$_nickname|$friendCode';

    final packet = _buildPacket(
      type: MeshMessageType.announce,
      content: content,
    );
    await _broadcast(packet);
  }

  /// Broadcast a friend request to a specific user
  /// Called when you add someone as a friend
  Future<void> broadcastFriendRequest(String targetFriendCode) async {
    if (_peerId == null || _nickname == null) return;

    // Content: "myNickname|myFriendCode"
    final myFriendCode = _generateFriendCode(_peerId!);
    final content = '$_nickname|$myFriendCode';

    final packet = _buildDirectPacket(
      type: MeshMessageType.friendRequest,
      content: content,
      targetFriendCode: targetFriendCode,
    );
    await _broadcast(packet);
  }

  /// Build a mesh packet with compact format
  ///
  /// Packet structure (max ~27 bytes for manufacturer data):
  /// - Type: 1 byte
  /// - TTL: 1 byte
  /// - Message ID: 2 bytes (hash of UUID)
  /// - Sender ID: 2 bytes (hash of peer ID)
  /// - Timestamp: 4 bytes (seconds since epoch, truncated)
  /// - Latitude: 4 bytes (float32) - 0x7FC00000 if not available (NaN)
  /// - Longitude: 4 bytes (float32) - 0x7FC00000 if not available (NaN)
  /// - Payload: remaining bytes (~9 bytes for text)
  Uint8List _buildPacket({
    required MeshMessageType type,
    required String content,
    int ttl = DEFAULT_TTL,
    double? latitude,
    double? longitude,
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
    builder.addByte(type.value); // 1 byte
    builder.addByte(ttl); // 1 byte
    builder.addByte((msgIdHash >> 8) & 0xFF); // 1 byte (msg ID high)
    builder.addByte(msgIdHash & 0xFF); // 1 byte (msg ID low)
    builder.addByte((senderIdHash >> 8) & 0xFF); // 1 byte (sender high)
    builder.addByte(senderIdHash & 0xFF); // 1 byte (sender low)

    // 4-byte timestamp
    final tsBytes = Uint8List(4);
    ByteData.view(tsBytes.buffer).setUint32(0, timestampSecs, Endian.big);
    builder.add(tsBytes); // 4 bytes

    // 4-byte latitude (float32) - NaN if not available
    final latBytes = Uint8List(4);
    ByteData.view(
      latBytes.buffer,
    ).setFloat32(0, latitude ?? double.nan, Endian.big);
    builder.add(latBytes); // 4 bytes

    // 4-byte longitude (float32) - NaN if not available
    final lonBytes = Uint8List(4);
    ByteData.view(
      lonBytes.buffer,
    ).setFloat32(0, longitude ?? double.nan, Endian.big);
    builder.add(lonBytes); // 4 bytes

    builder.add(contentBytes); // up to 9 bytes

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
    // Skip if already broadcasting (prevents race conditions)
    if (_advertisingBusy) {
      debugPrint("Skipping broadcast - already busy");
      return;
    }
    _advertisingBusy = true;

    try {
      // Stop existing advertising first if running
      if (_isAdvertising) {
        try {
          await _blePeripheral.stop();
          _isAdvertising = false;
        } catch (e) {
          debugPrint("Error stopping previous broadcast: $e");
        }
        // Wait for peripheral to fully stop
        await Future.delayed(const Duration(milliseconds: 150));
      }

      final advertiseData = AdvertiseData(
        manufacturerId: MESH_MANUFACTURER_ID,
        manufacturerData: packet,
        includeDeviceName: false,
      );

      await _blePeripheral.start(advertiseData: advertiseData);
      _isAdvertising = true;
      _statusController.add("Broadcasting...");

      // Schedule stop after 2 seconds (shorter than the 5s interval)
      await Future.delayed(const Duration(seconds: 2));
      
      if (_isAdvertising) {
        try {
          await _blePeripheral.stop();
          _isAdvertising = false;
          _statusController.add("Ready");
        } catch (e) {
          debugPrint("Error stopping broadcast: $e");
        }
      }
    } catch (e) {
      _isAdvertising = false;
      _errorController.add("Broadcast failed: $e");
    } finally {
      _advertisingBusy = false;
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

      // Periodic announcements every 5 seconds for friend presence detection
    // (2s broadcast + 3s gap to avoid race conditions)
    _announcementTimer = Timer.periodic(const Duration(seconds: 5), (_) {
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
    _directMessageController.close();
    _peerDiscoveryController.close();
    _friendCodeDiscoveryController.close();
    _friendRequestController.close();
    _statusController.close();
    _errorController.close();
  }
}
