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

/// Minimum announcement interval (randomized between MIN and MAX)
const int MIN_ANNOUNCE_INTERVAL_MS = 4000;

/// Maximum announcement interval
const int MAX_ANNOUNCE_INTERVAL_MS = 7000;

/// Broadcast duration in milliseconds
const int BROADCAST_DURATION_MS = 1500;

/// Number of times to retry friend requests
const int FRIEND_REQUEST_RETRY_COUNT = 5;

/// Delay between friend request retries (ms)
const int FRIEND_REQUEST_RETRY_DELAY_MS = 3000;

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
// Raw Packet Debug Model
// ============================================================================

/// Debug information about a raw BLE packet
class RawPacketDebug {
  final DateTime timestamp;
  final Uint8List rawBytes;
  final String hexString;
  final int? messageType;
  final String? messageTypeName;
  final int? ttl;
  final int? senderIdHash;
  final int? messageIdHash;
  final String? payload;
  final bool isDuplicate;
  final bool isFromSelf;
  final String? error;

  RawPacketDebug({
    required this.timestamp,
    required this.rawBytes,
    required this.hexString,
    this.messageType,
    this.messageTypeName,
    this.ttl,
    this.senderIdHash,
    this.messageIdHash,
    this.payload,
    this.isDuplicate = false,
    this.isFromSelf = false,
    this.error,
  });

  Map<String, dynamic> toMap() => {
    'timestamp': timestamp.toIso8601String(),
    'size': rawBytes.length,
    'hex': hexString,
    'type': messageTypeName ?? 'unknown ($messageType)',
    'ttl': ttl,
    'senderHash': senderIdHash?.toRadixString(16).padLeft(4, '0'),
    'msgIdHash': messageIdHash?.toRadixString(16).padLeft(4, '0'),
    'payload': payload,
    'isDuplicate': isDuplicate,
    'isFromSelf': isFromSelf,
    if (error != null) 'error': error,
  };
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

  // ---------------------------------------------------------------------------
  // Protocol Enhancement: Anti-Ping-Pong & Collision Prevention
  // ---------------------------------------------------------------------------

  /// Sequence number for outgoing packets (increments each transmission)
  int _sequenceNumber = 0;

  /// Last seen sequence number per sender (senderIdHash -> seqNum)
  /// Used to detect and ignore old/duplicate packets from same sender
  final Map<int, int> _lastSeenSequence = {};

  /// Last announcement time per sender (senderIdHash -> timestamp)
  /// Used to suppress rapid announcements from same peer (cooldown)
  final Map<int, DateTime> _lastAnnouncementTime = {};

  /// Minimum time between processing announcements from same peer
  static const Duration _announcementCooldown = Duration(seconds: 3);

  /// Hop-0 peers (direct neighbors we heard from without relay)
  /// These peers don't need their announcements relayed
  final Set<int> _directNeighbors = {};

  /// Pending friend requests to retry (targetFriendCode -> remaining retries)
  final Map<String, int> _pendingFriendRequests = {};

  /// Random instance for jitter
  final Random _random = Random();

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
  Timer? _friendRequestRetryTimer;
  Timer? _scanRestartTimer;

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
  final _rawPacketController = StreamController<RawPacketDebug>.broadcast();
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

  /// Stream of raw packets for debugging
  Stream<RawPacketDebug> get rawPacketStream => _rawPacketController.stream;

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
      // Start with shorter timeout for more responsive restarts
      // This allows scanning to be more continuous
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
        androidScanMode: AndroidScanMode.lowLatency, // Faster discovery
      );

      // Listen to scan results
      _scanSubscription = FlutterBluePlus.scanResults.listen(
        _processScanResults,
        onError: (error) {
          debugPrint("BLE Scan error: $error");
          _statusController.add("Scan error");
        },
      );

      // Restart scanning when it stops - faster restart
      FlutterBluePlus.isScanning.listen((scanning) {
        if (!scanning && _isScanning) {
          // Cancel previous restart timer to avoid duplicates
          _scanRestartTimer?.cancel();
          // Quick restart with small random delay to avoid sync
          final delay = 500 + _random.nextInt(500);
          _scanRestartTimer = Timer(Duration(milliseconds: delay), () {
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
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
        androidScanMode: AndroidScanMode.lowLatency,
      );
      debugPrint("Scan restarted successfully");
    } catch (e) {
      debugPrint("Failed to restart scanning: $e");
      // Try again with delay
      Future.delayed(const Duration(seconds: 1), () {
        if (_isScanning) _restartScanning();
      });
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
    if (data.length < 12) {
      // Emit debug info for too-short packet
      _rawPacketController.add(
        RawPacketDebug(
          timestamp: DateTime.now(),
          rawBytes: data,
          hexString: _bytesToHex(data),
          error: 'Packet too short (${data.length} bytes, need 12+)',
        ),
      );
      return;
    }

    // Build hex string for debug
    final hexString = _bytesToHex(data);

    try {
      int offset = 0;

      // Parse message type
      final typeValue = data[offset++];
      final type = MeshMessageType.fromValue(typeValue);
      if (type == null) {
        _rawPacketController.add(
          RawPacketDebug(
            timestamp: DateTime.now(),
            rawBytes: data,
            hexString: hexString,
            messageType: typeValue,
            error: 'Unknown message type: $typeValue',
          ),
        );
        return;
      }

      // Parse TTL
      final ttl = data[offset++];

      // Parse 2-byte message ID hash
      final msgIdHash = (data[offset] << 8) | data[offset + 1];
      offset += 2;
      final messageId = 'h:$msgIdHash'; // Use hash as ID

      // Parse 2-byte sender ID hash
      final senderIdHash = (data[offset] << 8) | data[offset + 1];
      offset += 2;
      final senderId = senderIdHash.toRadixString(16).padLeft(4, '0');

      // Parse payload for debug
      String? payloadPreview;
      try {
        if (data.length > offset + 12) {
          payloadPreview = utf8.decode(
            data.sublist(offset + 12),
            allowMalformed: true,
          );
        } else if (data.length > offset) {
          payloadPreview = utf8.decode(
            data.sublist(offset),
            allowMalformed: true,
          );
        }
      } catch (_) {}

      // Check for duplicate
      final isDuplicate = _processedMessageIds.containsKey(messageId);

      // Check if from self
      final myIdHash = _hashTo2Bytes(_peerId!);
      final isFromSelf = senderIdHash == myIdHash;

      // Emit raw packet debug info
      _rawPacketController.add(
        RawPacketDebug(
          timestamp: DateTime.now(),
          rawBytes: data,
          hexString: hexString,
          messageType: typeValue,
          messageTypeName: type.name,
          ttl: ttl,
          senderIdHash: senderIdHash,
          messageIdHash: msgIdHash,
          payload: payloadPreview,
          isDuplicate: isDuplicate,
          isFromSelf: isFromSelf,
        ),
      );

      // Deduplication check
      if (isDuplicate) return;
      _processedMessageIds[messageId] = DateTime.now();

      // Skip our own messages (compare hash)
      if (isFromSelf) return;

      // Calculate hop count early for neighbor detection
      final hopCount = DEFAULT_TTL - ttl;

      // Track direct neighbors (hop-0 = heard directly, not relayed)
      if (hopCount == 0) {
        _directNeighbors.add(senderIdHash);
      }

      // === PROTOCOL: Announcement Cooldown ===
      // For announcements, apply per-sender cooldown to prevent rapid ping-pong
      if (type == MeshMessageType.announce) {
        final lastAnnounce = _lastAnnouncementTime[senderIdHash];
        if (lastAnnounce != null) {
          final elapsed = DateTime.now().difference(lastAnnounce);
          if (elapsed < _announcementCooldown) {
            // Skip this announcement, we recently processed one from this sender
            debugPrint(
              'PROTOCOL: Skipping announcement from 0x${senderIdHash.toRadixString(16)} - cooldown (${elapsed.inMilliseconds}ms < ${_announcementCooldown.inMilliseconds}ms)',
            );
            return;
          }
        }
        // Update last announcement time for this sender
        _lastAnnouncementTime[senderIdHash] = DateTime.now();
      }

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

      // hopCount already calculated above for neighbor detection

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

        debugPrint(
          'Discovered peer: $nickname ($friendCode) - ${peers.length} total peers',
        );

        // Emit peer discovery with friend code info
        if (friendCode != null) {
          _friendCodeDiscoveryController.add(MapEntry(senderId, friendCode));

          // If we have a pending friend request to this person, they're now reachable
          if (hasPendingFriendRequest(friendCode)) {
            debugPrint(
              'Friend $friendCode is now reachable, will retry request',
            );
          }
        }

        notifyListeners();

        // === PROTOCOL: Smart Announcement Relay ===
        // Only relay announcements if:
        // 1. TTL > 0 (has hops remaining)
        // 2. hopCount > 0 (NOT from a direct neighbor - they broadcast themselves)
        // 3. hopCount < 3 (limit relay depth for announcements)
        // This prevents the ping-pong effect in 2-device scenarios
        if (ttl > 0 && hopCount > 0 && hopCount < 3) {
          debugPrint(
            'PROTOCOL: Relaying announcement from 0x${senderIdHash.toRadixString(16)} (hop $hopCount)',
          );
          _scheduleRelay(data, ttl, messageId);
        } else if (hopCount == 0) {
          debugPrint(
            'PROTOCOL: NOT relaying announcement from direct neighbor 0x${senderIdHash.toRadixString(16)}',
          );
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
      // My friend code is just my peer ID hash, so compare directly
      final myPeerIdHash = _hashTo2Bytes(_peerId!);
      final isForMe = targetIdHash == myPeerIdHash;

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

            // If we had a pending request to them, cancel it (mutual add)
            cancelPendingFriendRequest(senderFriendCode);

            debugPrint(
              'Received friend request from $senderFriendCode ($senderNickname)',
            );
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

  /// Generate friend code from peer ID (MUST match FriendService.generateFriendCode)
  /// Format: 4 hex characters (e.g., "3A9F") - compact for BLE payload
  String _generateFriendCode(String peerId) {
    // Use same 2-byte hash that's used for sender ID
    final hash = _hashTo2Bytes(peerId);
    return hash.toRadixString(16).padLeft(4, '0').toUpperCase();
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

    // Friend code IS the hex representation of the hash, parse it back
    final targetIdHash =
        int.tryParse(targetFriendCode.toUpperCase(), radix: 16) ?? 0;

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
  ///
  /// This queues the request for multiple retries to ensure delivery
  Future<void> broadcastFriendRequest(String targetFriendCode) async {
    if (_peerId == null || _nickname == null) return;

    // Queue for retries (will be sent multiple times)
    _pendingFriendRequests[targetFriendCode] = FRIEND_REQUEST_RETRY_COUNT;

    // Send immediately first time
    await _sendFriendRequestInternal(targetFriendCode);
    _pendingFriendRequests[targetFriendCode] = FRIEND_REQUEST_RETRY_COUNT - 1;

    debugPrint(
      'Queued friend request to $targetFriendCode for ${FRIEND_REQUEST_RETRY_COUNT} retries',
    );
  }

  /// Internal method to send a friend request packet
  Future<void> _sendFriendRequestInternal(String targetFriendCode) async {
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

  /// Cancel pending friend requests for a target
  void cancelPendingFriendRequest(String targetFriendCode) {
    _pendingFriendRequests.remove(targetFriendCode);
  }

  /// Check if a friend request is pending for a target
  bool hasPendingFriendRequest(String targetFriendCode) {
    return _pendingFriendRequests.containsKey(targetFriendCode);
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

  /// Broadcast a packet via BLE advertising with anti-collision
  ///
  /// Uses short broadcast windows and randomized timing to prevent
  /// two devices from consistently overlapping
  Future<bool> _broadcast(Uint8List packet) async {
    // Skip if already broadcasting (prevents race conditions)
    if (_advertisingBusy) {
      debugPrint("Skipping broadcast - already busy");
      return false;
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

      // Add random pre-broadcast jitter (0-200ms) to desync from other devices
      final preJitter = _random.nextInt(200);
      await Future.delayed(Duration(milliseconds: preJitter));

      final advertiseData = AdvertiseData(
        manufacturerId: MESH_MANUFACTURER_ID,
        manufacturerData: packet,
        includeDeviceName: false,
      );

      await _blePeripheral.start(advertiseData: advertiseData);
      _isAdvertising = true;
      _statusController.add("Broadcasting...");

      // Shorter broadcast window (1.5s) to allow more scan time
      await Future.delayed(const Duration(milliseconds: BROADCAST_DURATION_MS));

      if (_isAdvertising) {
        try {
          await _blePeripheral.stop();
          _isAdvertising = false;
          _statusController.add("Ready");
        } catch (e) {
          debugPrint("Error stopping broadcast: $e");
        }
      }
      return true;
    } catch (e) {
      _isAdvertising = false;
      _errorController.add("Broadcast failed: $e");
      return false;
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

    // Randomized announcement scheduling to prevent collision
    _scheduleNextAnnouncement();

    // Friend request retry timer (every 3 seconds)
    _friendRequestRetryTimer = Timer.periodic(
      const Duration(milliseconds: FRIEND_REQUEST_RETRY_DELAY_MS),
      (_) => _processPendingFriendRequests(),
    );
  }

  /// Schedule next announcement with random interval
  void _scheduleNextAnnouncement() {
    // Random interval between MIN and MAX to avoid sync with other devices
    final intervalMs =
        MIN_ANNOUNCE_INTERVAL_MS +
        _random.nextInt(MAX_ANNOUNCE_INTERVAL_MS - MIN_ANNOUNCE_INTERVAL_MS);

    _announcementTimer?.cancel();
    _announcementTimer = Timer(Duration(milliseconds: intervalMs), () async {
      await announcePresence();
      // Schedule next one
      _scheduleNextAnnouncement();
    });
  }

  /// Process pending friend requests (retry mechanism)
  Future<void> _processPendingFriendRequests() async {
    if (_pendingFriendRequests.isEmpty || _advertisingBusy) return;

    // Get one pending request to process
    final entries = _pendingFriendRequests.entries.toList();
    if (entries.isEmpty) return;

    for (final entry in entries) {
      final targetFriendCode = entry.key;
      final retriesLeft = entry.value;

      if (retriesLeft <= 0) {
        _pendingFriendRequests.remove(targetFriendCode);
        continue;
      }

      // Send the friend request
      debugPrint(
        'Retrying friend request to $targetFriendCode (${retriesLeft} left)',
      );
      await _sendFriendRequestInternal(targetFriendCode);
      _pendingFriendRequests[targetFriendCode] = retriesLeft - 1;

      // Only process one per cycle to avoid flooding
      break;
    }
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

    // Cleanup old announcement cooldown times
    _lastAnnouncementTime.removeWhere((_, timestamp) {
      return now.difference(timestamp) > const Duration(minutes: 2);
    });

    // Cleanup stale direct neighbors (if we haven't heard from them in 2 minutes)
    // Note: This is a simple cleanup; directNeighbors set is refreshed on each packet
    // We keep it to avoid memory growth but it's reset naturally

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

  /// Convert bytes to hex string for debugging
  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  }

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
    _friendRequestRetryTimer?.cancel();
    _scanRestartTimer?.cancel();
    _scanSubscription?.cancel();

    _relayQueue.clear();
    _pendingFriendRequests.clear();

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
    _rawPacketController.close();
    _statusController.close();
    _errorController.close();
  }
}
