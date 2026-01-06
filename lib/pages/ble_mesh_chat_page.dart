import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import '../services/ble_mesh_service.dart';

/// BLE Mesh Chat Page
///
/// Features:
/// - Real-time mesh chat with nearby devices
/// - Multi-hop message relay (messages hop between devices)
/// - Peer discovery and status display
/// - Location sharing in messages
/// - Emotion detection from text
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

                  // Location info
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
                        ],
                      ),
                    ),

                  // Emotion indicator
                  if (message.emotion != null && message.emotion!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _getEmotionEmoji(message.emotion!),
                        style: const TextStyle(fontSize: 14),
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

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
  }

  String _getEmotionEmoji(String emotion) {
    switch (emotion.toLowerCase()) {
      case 'angry':
        return '😠';
      case 'sad':
        return '😢';
      case 'worried':
        return '😰';
      case 'excited':
        return '🤩';
      case 'happy':
        return '😊';
      case 'grateful':
        return '🙏';
      case 'surprised':
        return '😲';
      case 'laughing':
        return '😂';
      case 'confused':
        return '😕';
      case 'tired':
        return '😴';
      case 'curious':
        return '🤔';
      case 'bored':
        return '😑';
      case 'loving':
        return '❤️';
      case 'neutral':
        return '😐';
      default:
        return '💬';
    }
  }
}
