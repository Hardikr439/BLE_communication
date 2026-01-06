import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/friend.dart';
import '../services/friend_service.dart';
import '../services/ble_mesh_service.dart';

/// Private Chat Page - 1:1 chat with a specific friend
///
/// Features:
/// - Direct messaging with friend
/// - Online status indicator
/// - Message delivery status
/// - Auto-scroll to latest
class PrivateChatPage extends StatefulWidget {
  final Friend friend;

  const PrivateChatPage({super.key, required this.friend});

  @override
  State<PrivateChatPage> createState() => _PrivateChatPageState();
}

class _PrivateChatPageState extends State<PrivateChatPage> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();

  final _friendService = FriendService.instance;
  final _meshService = BleMeshService.instance;

  StreamSubscription? _messageSubscription;
  StreamSubscription? _friendSubscription;

  late Friend _friend;
  List<DirectMessage> _messages = [];

  // Theme colors
  static const Color primaryBlue = Color(0xFF5396FF);
  static const Color bgLight = Color(0xFFF5F7FA);
  static const Color bgWhite = Colors.white;
  static const Color textDark = Color(0xFF2C3E50);
  static const Color textLight = Color(0xFF7F8C8D);
  static const Color successGreen = Color(0xFF27AE60);

  @override
  void initState() {
    super.initState();
    _friend = widget.friend;
    _loadMessages();
    _markAsRead();
    _setupListeners();
  }

  void _loadMessages() {
    _messages = _friendService.getChatHistory(_friend.id);
  }

  void _markAsRead() {
    _friendService.markAsRead(_friend.id);
  }

  void _setupListeners() {
    // Listen for new messages
    _messageSubscription = _friendService.messageStream.listen((msg) {
      if (msg.senderId == _friend.id || msg.receiverId == _friend.id) {
        setState(() {
          _messages = _friendService.getChatHistory(_friend.id);
        });
        _scrollToBottom();
        _markAsRead();
      }
    });

    // Listen for friend status updates
    _friendSubscription = _friendService.friendUpdates.listen((friend) {
      if (friend.id == _friend.id) {
        setState(() => _friend = friend);
      }
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();
    _focusNode.requestFocus();

    try {
      // Create message
      final message = DirectMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        senderId: _friendService.myFriendCode!,
        receiverId: _friend.id,
        content: text,
        timestamp: DateTime.now(),
        isMe: true,
      );

      // Save locally
      await _friendService.addSentMessage(message);

      // Send via mesh (with target)
      await _meshService.sendDirectMessage(text, targetFriendCode: _friend.id);

      HapticFeedback.lightImpact();
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to send: $e')));
    }
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _friendSubscription?.cancel();
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
      body: Column(
        children: [
          // Messages
          Expanded(
            child: _messages.isEmpty
                ? _buildEmptyState()
                : _buildMessagesList(),
          ),

          // Input bar
          _buildInputBar(),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: bgWhite,
      elevation: 1,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: textDark),
        onPressed: () => Navigator.pop(context),
      ),
      title: Row(
        children: [
          // Avatar
          Stack(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: primaryBlue.withOpacity(0.1),
                child: Text(
                  _friend.nickname.isNotEmpty
                      ? _friend.nickname[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                    color: primaryBlue,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (_friend.isOnline)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: successGreen,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),

          // Name & status
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _friend.nickname,
                  style: const TextStyle(
                    color: textDark,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _friend.isOnline
                      ? 'Online'
                      : _friend.lastSeen != null
                      ? 'Last seen ${_formatTime(_friend.lastSeen!)}'
                      : 'Offline',
                  style: TextStyle(
                    color: _friend.isOnline ? successGreen : textLight,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.info_outline, color: textDark),
          onPressed: _showFriendInfo,
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 80,
              color: textLight.withOpacity(0.3),
            ),
            const SizedBox(height: 20),
            Text(
              'No messages yet',
              style: TextStyle(
                color: textDark,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Start a conversation with ${_friend.nickname}',
              textAlign: TextAlign.center,
              style: TextStyle(color: textLight, fontSize: 14),
            ),
            const SizedBox(height: 8),
            if (!_friend.isOnline)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.info_outline, color: Colors.orange, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      'Messages will be delivered when they come online',
                      style: TextStyle(
                        color: Colors.orange.shade700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessagesList() {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        final showDate =
            index == 0 ||
            !_isSameDay(_messages[index - 1].timestamp, message.timestamp);

        return Column(
          children: [
            if (showDate) _buildDateDivider(message.timestamp),
            _buildMessageBubble(message),
          ],
        );
      },
    );
  }

  Widget _buildDateDivider(DateTime date) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Expanded(child: Divider(color: textLight.withOpacity(0.3))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              _formatDate(date),
              style: TextStyle(
                color: textLight,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(child: Divider(color: textLight.withOpacity(0.3))),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(DirectMessage message) {
    final isMe = message.isMe;

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
            // Message bubble
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isMe ? primaryBlue : bgWhite,
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
              child: Text(
                message.content,
                style: TextStyle(
                  color: isMe ? Colors.white : textDark,
                  fontSize: 15,
                ),
              ),
            ),

            // Timestamp & status
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatMessageTime(message.timestamp),
                    style: TextStyle(
                      color: textLight.withOpacity(0.7),
                      fontSize: 11,
                    ),
                  ),
                  if (isMe) ...[
                    const SizedBox(width: 4),
                    Icon(
                      message.isRead
                          ? Icons.done_all
                          : message.isDelivered
                          ? Icons.done_all
                          : Icons.done,
                      size: 14,
                      color: message.isRead
                          ? primaryBlue
                          : textLight.withOpacity(0.5),
                    ),
                  ],
                ],
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
                  hintText: 'Message ${_friend.nickname}...',
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

  void _showFriendInfo() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Avatar
              CircleAvatar(
                radius: 40,
                backgroundColor: primaryBlue.withOpacity(0.1),
                child: Text(
                  _friend.nickname.isNotEmpty
                      ? _friend.nickname[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                    color: primaryBlue,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Name
              Text(
                _friend.nickname,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: textDark,
                ),
              ),

              // Friend code
              const SizedBox(height: 4),
              Text(
                _friend.id,
                style: TextStyle(
                  color: textLight,
                  fontSize: 14,
                  fontFamily: 'monospace',
                ),
              ),

              const SizedBox(height: 16),

              // Status
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: _friend.isOnline
                      ? successGreen.withOpacity(0.1)
                      : textLight.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _friend.isOnline ? successGreen : textLight,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _friend.isOnline ? 'Online in mesh' : 'Offline',
                      style: TextStyle(
                        color: _friend.isOnline ? successGreen : textLight,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // Info
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: bgLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: textLight, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Messages are sent via Bluetooth mesh. They may be relayed through other devices to reach your friend.',
                        style: TextStyle(color: textLight, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  String _formatMessageTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDay = DateTime(date.year, date.month, date.day);

    if (messageDay == today) return 'Today';
    if (messageDay == today.subtract(const Duration(days: 1)))
      return 'Yesterday';

    return '${date.day}/${date.month}/${date.year}';
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}
