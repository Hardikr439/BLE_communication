import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../services/ble_mesh_service.dart';
import '../services/caching_tile_provider.dart';

/// BLE Mesh Chat Page
///
/// Features:
/// - Real-time mesh chat with nearby devices
/// - Multi-hop message relay (messages hop between devices)
/// - Peer discovery and status display
/// - Location sharing in messages
/// - Mesh network statistics
/// - Works offline via Bluetooth
class BleMeshChatPage extends StatefulWidget {
  const BleMeshChatPage({super.key});

  @override
  State<BleMeshChatPage> createState() => _BleMeshChatPageState();
}

class _BleMeshChatPageState extends State<BleMeshChatPage> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  late BleMeshService _meshService;

  StreamSubscription? _messageSubscription;
  StreamSubscription? _statusSubscription;
  StreamSubscription? _errorSubscription;

  String _status = "Initializing...";
  bool _isInitializing = true;
  String? _errorMessage;

  // Theme colors
  static const Color primaryBlue = Color(0xFF5396FF);
  static const Color primaryYellow = Color(0xFFF6C560);
  static const Color bgLight = Color(0xFFF5F7FA);
  static const Color bgWhite = Colors.white;
  static const Color textDark = Color(0xFF2C3E50);
  static const Color textLight = Color(0xFF7F8C8D);
  static const Color successGreen = Color(0xFF27AE60);
  static const Color dangerRed = Color(0xFFE74C3C);

  @override
  void initState() {
    super.initState();
    _meshService = BleMeshService.instance;
    _initService();
  }

  Future<void> _initService() async {
    try {
      setState(() {
        _isInitializing = true;
        _errorMessage = null;
      });

      await _meshService.init();

      if (!mounted) return;

      setState(() {
        _status = "Connected";
        _isInitializing = false;
      });

      // Listen to new messages
      _messageSubscription = _meshService.messageStream.listen(
        (msg) {
          if (mounted) {
            setState(() {});
            _scrollToBottom();

            // Haptic feedback for received messages
            if (!msg.isMe) {
              HapticFeedback.lightImpact();
            }
          }
        },
        onError: (error) {
          if (mounted) {
            setState(() => _errorMessage = "Message stream error: $error");
          }
        },
      );

      // Listen to status changes
      _statusSubscription = _meshService.statusStream.listen(
        (status) {
          if (mounted) setState(() => _status = status);
        },
        onError: (error) {
          if (mounted) {
            setState(() => _errorMessage = "Status error: $error");
          }
        },
      );

      // Listen to errors
      _errorSubscription = _meshService.errorStream.listen((error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error), backgroundColor: dangerRed),
          );
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _errorMessage = "Failed to initialize: $e";
        _status = "Error";
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("BLE initialization failed: $e"),
          backgroundColor: dangerRed,
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: "Retry",
            textColor: Colors.white,
            onPressed: _initService,
          ),
        ),
      );
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text("Please enter a message"),
          backgroundColor: textLight,
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    try {
      await _meshService.sendMessage(text);
      _messageController.clear();
      _focusNode.requestFocus();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Failed to send: $e"),
          backgroundColor: dangerRed,
        ),
      );
    }
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _statusSubscription?.cancel();
    _errorSubscription?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgLight,
      appBar: _buildAppBar(),
      body: _isInitializing
          ? _buildLoadingState()
          : _errorMessage != null
          ? _buildErrorState()
          : _buildChatInterface(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final stats = _meshService.getStats();
    final peerCount = stats['activePeers'] ?? 0;
    final relayedCount = stats['messagesRelayed'] ?? 0;

    return AppBar(
      backgroundColor: bgWhite,
      elevation: 1,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: textDark),
        onPressed: () => Navigator.pop(context),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Mesh Chat",
            style: TextStyle(
              color: textDark,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _status == "Connected" || _status.contains("Ready")
                      ? successGreen
                      : _status.contains("Error")
                      ? dangerRed
                      : primaryYellow,
                ),
              ),
              Text(
                "$peerCount peers • $relayedCount relayed",
                style: const TextStyle(color: textLight, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.info_outline, color: textDark),
          onPressed: _showNetworkStats,
          tooltip: 'Network Stats',
        ),
        IconButton(
          icon: const Icon(Icons.sos, color: dangerRed),
          onPressed: () => Navigator.pushNamed(context, '/sos'),
          tooltip: 'SOS',
        ),
      ],
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            "Connecting to mesh network...",
            style: TextStyle(color: textLight, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            "Scanning for nearby devices",
            style: TextStyle(color: textLight.withOpacity(0.7), fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: dangerRed, size: 64),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? "An error occurred",
              textAlign: TextAlign.center,
              style: const TextStyle(color: textDark, fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _initService,
              icon: const Icon(Icons.refresh),
              label: const Text("Retry"),
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryBlue,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatInterface() {
    return Column(
      children: [
        // Peers bar
        _buildPeersBar(),

        // Messages list
        Expanded(
          child: _meshService.messages.isEmpty
              ? _buildEmptyState()
              : _buildMessagesList(),
        ),

        // Input bar
        _buildInputBar(),
      ],
    );
  }

  Widget _buildPeersBar() {
    final peers = _meshService.peers.values.toList();
    if (peers.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: bgWhite,
        child: Row(
          children: [
            const Icon(Icons.wifi_tethering, color: textLight, size: 18),
            const SizedBox(width: 8),
            Text(
              "Scanning for peers...",
              style: TextStyle(color: textLight, fontSize: 13),
            ),
            const Spacer(),
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: primaryBlue.withOpacity(0.5),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(vertical: 8),
      color: bgWhite,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: peers.length,
        itemBuilder: (context, index) {
          final peer = peers[index];
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: peer.isOnline
                  ? successGreen.withOpacity(0.1)
                  : textLight.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: peer.isOnline ? successGreen : textLight,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: peer.isOnline ? successGreen : textLight,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  peer.nickname,
                  style: TextStyle(
                    color: peer.isOnline ? textDark : textLight,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 80,
            color: textLight.withOpacity(0.3),
          ),
          const SizedBox(height: 16),
          const Text(
            "No messages yet",
            style: TextStyle(
              color: textDark,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Messages are shared via Bluetooth mesh",
            style: TextStyle(color: textLight, fontSize: 14),
          ),
          const SizedBox(height: 4),
          Text(
            "Works offline without internet!",
            style: TextStyle(color: textLight.withOpacity(0.7), fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildMessagesList() {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _meshService.messages.length,
      itemBuilder: (context, index) {
        final message = _meshService.messages[index];
        return _buildMessageBubble(message);
      },
    );
  }

  Widget _buildMessageBubble(MeshMessage message) {
    final isMe = message.isMe;
    final hasLocation = message.latitude != null && message.longitude != null;
    final isSos = message.type == MeshMessageType.sos;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        child: Column(
          crossAxisAlignment: isMe
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            // Sender info for received messages
            if (!isMe)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      message.senderNickname,
                      style: const TextStyle(
                        color: textLight,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (message.wasRelayed) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: primaryBlue.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${message.hopCount} hops',
                          style: TextStyle(color: primaryBlue, fontSize: 9),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

            // Message bubble
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isSos
                    ? dangerRed
                    : isMe
                    ? primaryBlue
                    : bgWhite,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMe ? 16 : 4),
                  bottomRight: Radius.circular(isMe ? 4 : 16),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // SOS indicator
                  if (isSos)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.warning, color: Colors.white, size: 14),
                          SizedBox(width: 4),
                          Text(
                            'SOS ALERT',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Message content
                  Text(
                    message.content,
                    style: TextStyle(
                      color: isSos || isMe ? Colors.white : textDark,
                      fontSize: 15,
                    ),
                  ),

                  // Location info with GPS button
                  if (hasLocation)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.location_on,
                            size: 12,
                            color: (isSos || isMe ? Colors.white : textLight)
                                .withOpacity(0.7),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${message.latitude!.toStringAsFixed(4)}, '
                            '${message.longitude!.toStringAsFixed(4)}',
                            style: TextStyle(
                              color: (isSos || isMe ? Colors.white : textLight)
                                  .withOpacity(0.7),
                              fontSize: 10,
                              fontFamily: 'monospace',
                            ),
                          ),
                          const SizedBox(width: 6),
                          // GPS Map Button
                          GestureDetector(
                            onTap: () => _showLocationMap(
                              message.latitude!,
                              message.longitude!,
                              message.senderNickname,
                              isSos,
                            ),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: (isSos || isMe)
                                    ? Colors.white.withOpacity(0.2)
                                    : primaryBlue.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: (isSos || isMe)
                                      ? Colors.white.withOpacity(0.4)
                                      : primaryBlue.withOpacity(0.3),
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.map_outlined,
                                    size: 10,
                                    color: (isSos || isMe)
                                        ? Colors.white
                                        : primaryBlue,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    'GPS',
                                    style: TextStyle(
                                      color: (isSos || isMe)
                                          ? Colors.white
                                          : primaryBlue,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),

            // Timestamp
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 4, right: 4),
              child: Text(
                _formatTime(message.timestamp),
                style: TextStyle(
                  color: textLight.withOpacity(0.6),
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: bgWhite,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Row(
        children: [
          // Location button
          IconButton(
            onPressed: _attachLocation,
            icon: const Icon(Icons.location_on_outlined),
            color: textLight,
            tooltip: 'Attach Location',
          ),

          // Text input
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: bgLight,
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: _messageController,
                focusNode: _focusNode,
                decoration: InputDecoration(
                  hintText: 'Type a message...',
                  hintStyle: TextStyle(color: textLight),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
                maxLines: null,
                keyboardType: TextInputType.multiline,
              ),
            ),
          ),

          const SizedBox(width: 8),

          // Send button
          Container(
            decoration: BoxDecoration(
              color: primaryBlue,
              shape: BoxShape.circle,
            ),
            child: IconButton(
              onPressed: _sendMessage,
              icon: const Icon(Icons.send, color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _attachLocation() async {
    try {
      Position? position = await Geolocator.getLastKnownPosition();
      position ??= await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      if (mounted) {
        final coords =
            '📍 ${position.latitude.toStringAsFixed(5)}, '
            '${position.longitude.toStringAsFixed(5)}';
        _messageController.text += coords;
        _focusNode.requestFocus();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not get location: $e'),
            backgroundColor: dangerRed,
          ),
        );
      }
    }
  }

  void _showNetworkStats() {
    final stats = _meshService.getStats();

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Mesh Network Statistics',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: textDark,
                ),
              ),
              const SizedBox(height: 20),
              _buildStatRow('Your Peer ID', stats['peerId'] ?? 'Unknown'),
              _buildStatRow('Nickname', stats['nickname'] ?? 'Unknown'),
              const Divider(height: 24),
              _buildStatRow('Active Peers', '${stats['activePeers']}'),
              _buildStatRow('Total Peers Seen', '${stats['totalPeers']}'),
              const Divider(height: 24),
              _buildStatRow('Messages Sent', '${stats['messagesSent']}'),
              _buildStatRow(
                'Messages Received',
                '${stats['messagesReceived']}',
              ),
              _buildStatRow('Messages Relayed', '${stats['messagesRelayed']}'),
              const Divider(height: 24),
              _buildStatRow('Cache Size', '${stats['cacheSize']}'),
              _buildStatRow('Queued Relays', '${stats['queuedRelays']}'),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: textLight)),
          Text(
            value,
            style: const TextStyle(
              color: textDark,
              fontWeight: FontWeight.w500,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  /// Show location map in a bottom sheet with sender location (red) and user location (blue)
  void _showLocationMap(
    double senderLat,
    double senderLon,
    String senderName,
    bool isSos,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _LocationMapSheet(
        senderLatitude: senderLat,
        senderLongitude: senderLon,
        senderName: senderName,
        isSos: isSos,
      ),
    );
  }

  /// Parse message content in format: "message|lat,lon"
  /// Helper method for string-based message formats
  Map<String, String?> _parseMessageContent(String content) {
    final parts = content.split('|');
    return {
      'text': parts.isNotEmpty ? parts[0] : content,
      'location': parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null,
    };
  }

  /// Open location map from string format "lat,lon"
  /// Helper method for string-based message formats
  void _openLocationOnMap({
    required String senderName,
    required String location,
  }) {
    final parts = location.split(',');
    if (parts.length != 2) return;

    final lat = double.tryParse(parts[0]);
    final lon = double.tryParse(parts[1]);
    if (lat == null || lon == null) return;

    _showLocationMap(lat, lon, senderName, false);
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
  }
}

// ============================================================================
// Location Map Bottom Sheet Widget
// ============================================================================

/// Bottom sheet widget showing sender and user locations on a map
class _LocationMapSheet extends StatefulWidget {
  final double senderLatitude;
  final double senderLongitude;
  final String senderName;
  final bool isSos;

  const _LocationMapSheet({
    required this.senderLatitude,
    required this.senderLongitude,
    required this.senderName,
    required this.isSos,
  });

  @override
  State<_LocationMapSheet> createState() => _LocationMapSheetState();
}

class _LocationMapSheetState extends State<_LocationMapSheet> {
  final MapController _mapController = MapController();

  Position? _userPosition;
  bool _isLoadingLocation = true;
  String? _locationError;
  double? _distanceMeters;
  bool _isCachingTiles = false;
  String? _cacheStatus;

  // Theme colors (matching parent)
  static const Color primaryBlue = Color(0xFF5396FF);
  static const Color bgWhite = Colors.white;
  static const Color textDark = Color(0xFF2C3E50);
  static const Color textLight = Color(0xFF7F8C8D);
  static const Color dangerRed = Color(0xFFE74C3C);

  @override
  void initState() {
    super.initState();
    _initializeCacheAndLocation();
  }

  Future<void> _initializeCacheAndLocation() async {
    // Initialize tile cache
    await CachingTileProvider.initialize();
    
    // Start fetching user location
    _fetchUserLocation();
    
    // Pre-cache tiles around sender's location for offline use
    _preCacheTiles();
  }

  Future<void> _preCacheTiles() async {
    if (!mounted) return;
    setState(() {
      _isCachingTiles = true;
      _cacheStatus = 'Caching map tiles...';
    });

    try {
      await preCacheTilesAroundLocation(
        latitude: widget.senderLatitude,
        longitude: widget.senderLongitude,
        minZoom: 12,
        maxZoom: 16,
        radiusTiles: 3,
        onProgress: (cached, total) {
          if (mounted) {
            setState(() {
              _cacheStatus = 'Cached $cached/$total tiles';
            });
          }
        },
      );
    } catch (e) {
      debugPrint('Failed to pre-cache tiles: $e');
    }

    if (mounted) {
      setState(() {
        _isCachingTiles = false;
        _cacheStatus = null;
      });
    }
  }

  Future<void> _fetchUserLocation() async {
    setState(() {
      _isLoadingLocation = true;
      _locationError = null;
    });

    try {
      // Try cached location first (faster)
      Position? position = await Geolocator.getLastKnownPosition();

      // If no cached location or it's too old, get fresh position
      if (position == null) {
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        ).timeout(const Duration(seconds: 10));
      }

      if (mounted) {
        setState(() {
          _userPosition = position;
          _isLoadingLocation = false;
        });

        // Calculate distance between sender and user
        _calculateDistance();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingLocation = false;
          _locationError = "Could not get your location";
        });
      }
    }
  }

  void _calculateDistance() {
    if (_userPosition == null) return;

    final distance = Geolocator.distanceBetween(
      widget.senderLatitude,
      widget.senderLongitude,
      _userPosition!.latitude,
      _userPosition!.longitude,
    );

    setState(() {
      _distanceMeters = distance;
    });
  }

  String _formatDistance(double meters) {
    if (meters < 1000) {
      return '${meters.toStringAsFixed(0)} m';
    } else {
      return '${(meters / 1000).toStringAsFixed(2)} km';
    }
  }

  void _centerOnSender() {
    _mapController.move(
      LatLng(widget.senderLatitude, widget.senderLongitude),
      15,
    );
  }

  void _centerOnUser() {
    if (_userPosition != null) {
      _mapController.move(
        LatLng(_userPosition!.latitude, _userPosition!.longitude),
        15,
      );
    }
  }

  void _fitBothLocations() {
    if (_userPosition == null) {
      _centerOnSender();
      return;
    }

    final bounds = LatLngBounds(
      LatLng(widget.senderLatitude, widget.senderLongitude),
      LatLng(_userPosition!.latitude, _userPosition!.longitude),
    );

    _mapController.fitCamera(
      CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(50)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final senderLocation = LatLng(widget.senderLatitude, widget.senderLongitude);

    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: const BoxDecoration(
        color: bgWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: textLight.withOpacity(0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: widget.isSos
                        ? dangerRed.withOpacity(0.1)
                        : primaryBlue.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    widget.isSos ? Icons.sos : Icons.location_on,
                    color: widget.isSos ? dangerRed : primaryBlue,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.isSos ? 'SOS Location' : 'Message Location',
                        style: TextStyle(
                          color: widget.isSos ? dangerRed : textDark,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'From: ${widget.senderName}',
                        style: const TextStyle(color: textLight, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                // Distance badge
                if (_distanceMeters != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: primaryBlue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.straighten,
                          size: 14,
                          color: primaryBlue,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _formatDistance(_distanceMeters!),
                          style: const TextStyle(
                            color: primaryBlue,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          // Map
          Expanded(
            child: Stack(
              children: [
                // Offline fallback background + Map
                Stack(
                  children: [
                    // Offline fallback grid background (always visible behind map)
                    ClipRRect(
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F4E8),
                          // Simple grid pattern for offline
                          image: const DecorationImage(
                            image: AssetImage(''), // Will show grid color
                            fit: BoxFit.cover,
                            opacity: 0.1,
                          ),
                        ),
                        child: CustomPaint(
                          painter: _GridPainter(),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),

                    // Actual map with tiles (loads over fallback when online)
                    ClipRRect(
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                      ),
                      child: FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: senderLocation,
                          initialZoom: 15,
                          minZoom: 3,
                          maxZoom: 18,
                        ),
                        children: [
                          // Map tiles using flutter_map package (OpenStreetMap tile source)
                          TileLayer(
                            urlTemplate:
                                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.example.ble_mesh_app',
                            maxZoom: 18,
                            tileProvider: CachingTileProvider(),
                            // Show background color when tiles fail
                            fallbackUrl: null,
                            errorTileCallback: (tile, error, stackTrace) {
                              // Silently handle tile errors - grid shows through
                            },
                          ),

                          // Markers layer
                          MarkerLayer(
                            markers: [
                              // Sender location - Red marker
                              Marker(
                                point: senderLocation,
                                width: 50,
                                height: 50,
                                child: _buildSenderMarker(),
                              ),

                              // User location - Blue dot (if available)
                              if (_userPosition != null)
                                Marker(
                                  point: LatLng(
                                    _userPosition!.latitude,
                                    _userPosition!.longitude,
                                  ),
                                  width: 30,
                                  height: 30,
                                  child: _buildUserMarker(),
                                ),
                            ],
                          ),

                          // Draw line between sender and user
                          if (_userPosition != null)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: [
                                    senderLocation,
                                LatLng(
                                  _userPosition!.latitude,
                                  _userPosition!.longitude,
                                ),
                              ],
                              color: primaryBlue.withOpacity(0.5),
                              strokeWidth: 2,
                              pattern: const StrokePattern.dotted(),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                  ],
                ),

                // Offline mode indicator
                Positioned(
                  bottom: 16,
                  left: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: bgWhite.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.offline_bolt,
                          size: 14,
                          color: textLight,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Offline mode - grid view',
                          style: TextStyle(
                            color: textLight,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Loading overlay for user location
                if (_isLoadingLocation || _isCachingTiles)
                  Positioned(
                    top: 16,
                    left: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: bgWhite,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: primaryBlue,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _isLoadingLocation 
                                ? 'Getting your location...'
                                : (_cacheStatus ?? 'Caching map...'),
                            style: const TextStyle(color: textLight, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Error message for location
                if (_locationError != null)
                  Positioned(
                    top: 16,
                    left: 16,
                    right: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: dangerRed.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: dangerRed.withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.warning_amber,
                            size: 16,
                            color: dangerRed,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _locationError!,
                              style: const TextStyle(
                                color: dangerRed,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: _fetchUserLocation,
                            child: const Icon(
                              Icons.refresh,
                              size: 18,
                              color: dangerRed,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Map control buttons
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: Column(
                    children: [
                      // Fit both locations button
                      if (_userPosition != null)
                        _buildMapButton(
                          icon: Icons.fit_screen,
                          onTap: _fitBothLocations,
                          tooltip: 'Fit both locations',
                        ),
                      const SizedBox(height: 8),

                      // Center on sender button
                      _buildMapButton(
                        icon: Icons.person_pin_circle,
                        onTap: _centerOnSender,
                        tooltip: 'Sender location',
                        color: dangerRed,
                      ),
                      const SizedBox(height: 8),

                      // Center on user button
                      _buildMapButton(
                        icon: Icons.my_location,
                        onTap: _centerOnUser,
                        tooltip: 'Your location',
                        color: primaryBlue,
                        enabled: _userPosition != null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Bottom info bar
          Container(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: MediaQuery.of(context).padding.bottom + 12,
            ),
            decoration: BoxDecoration(
              color: bgWhite,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            child: Row(
              children: [
                // Sender location info
                Expanded(
                  child: _buildLocationInfo(
                    icon: Icons.location_on,
                    iconColor: dangerRed,
                    label: 'Sender',
                    coordinates:
                        '${widget.senderLatitude.toStringAsFixed(5)}, '
                        '${widget.senderLongitude.toStringAsFixed(5)}',
                  ),
                ),
                Container(
                  width: 1,
                  height: 40,
                  color: textLight.withOpacity(0.2),
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                ),
                // User location info
                Expanded(
                  child: _userPosition != null
                      ? _buildLocationInfo(
                          icon: Icons.my_location,
                          iconColor: primaryBlue,
                          label: 'You',
                          coordinates:
                              '${_userPosition!.latitude.toStringAsFixed(5)}, '
                              '${_userPosition!.longitude.toStringAsFixed(5)}',
                        )
                      : _buildLocationInfo(
                          icon: Icons.my_location,
                          iconColor: textLight,
                          label: 'You',
                          coordinates: _isLoadingLocation
                              ? 'Loading...'
                              : 'Unavailable',
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSenderMarker() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: widget.isSos ? dangerRed : dangerRed,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: (widget.isSos ? dangerRed : dangerRed).withOpacity(0.4),
                blurRadius: 8,
                spreadRadius: 2,
              ),
            ],
          ),
          child: const Icon(Icons.person, color: Colors.white, size: 18),
        ),
        CustomPaint(
          size: const Size(12, 8),
          painter: _TrianglePainter(color: widget.isSos ? dangerRed : dangerRed),
        ),
      ],
    );
  }

  Widget _buildUserMarker() {
    return Container(
      decoration: BoxDecoration(
        color: primaryBlue,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
            color: primaryBlue.withOpacity(0.4),
            blurRadius: 8,
            spreadRadius: 2,
          ),
        ],
      ),
    );
  }

  Widget _buildMapButton({
    required IconData icon,
    required VoidCallback onTap,
    required String tooltip,
    Color color = textDark,
    bool enabled = true,
  }) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: enabled ? bgWhite : bgWhite.withOpacity(0.7),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 8,
            ),
          ],
        ),
        child: Icon(
          icon,
          color: enabled ? color : textLight.withOpacity(0.5),
          size: 22,
        ),
      ),
    );
  }

  Widget _buildLocationInfo({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String coordinates,
  }) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: textLight,
                  fontSize: 11,
                ),
              ),
              Text(
                coordinates,
                style: const TextStyle(
                  color: textDark,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Custom painter for marker triangle pointer
class _TrianglePainter extends CustomPainter {
  final Color color;

  _TrianglePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = ui.Path()
      ..moveTo(size.width / 2, size.height)
      ..lineTo(0, 0)
      ..lineTo(size.width, 0)
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Grid painter for offline map fallback background
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFCCDDCC)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;

    const gridSize = 40.0;

    // Draw vertical lines
    for (double x = 0; x <= size.width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    // Draw horizontal lines
    for (double y = 0; y <= size.height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    // Draw compass rose in center
    final center = Offset(size.width / 2, size.height / 2);
    final compassPaint = Paint()
      ..color = const Color(0xFFAABBAA)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // Draw compass circle
    canvas.drawCircle(center, 30, compassPaint);
    canvas.drawCircle(center, 60, compassPaint..color = const Color(0xFFCCDDCC));

    // Draw N/S/E/W lines
    canvas.drawLine(
      Offset(center.dx, center.dy - 60),
      Offset(center.dx, center.dy + 60),
      compassPaint..color = const Color(0xFFAABBAA),
    );
    canvas.drawLine(
      Offset(center.dx - 60, center.dy),
      Offset(center.dx + 60, center.dy),
      compassPaint,
    );

    // Draw N indicator
    final textPainter = TextPainter(
      text: const TextSpan(
        text: 'N',
        style: TextStyle(
          color: Color(0xFF889988),
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(center.dx - textPainter.width / 2, center.dy - 80),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
