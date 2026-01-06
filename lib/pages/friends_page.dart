import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/friend.dart';
import '../services/friend_service.dart';
import '../services/ble_mesh_service.dart';

/// Friends List Page
///
/// Features:
/// - View all friends with online status
/// - Add new friend by code
/// - Remove friends
/// - Navigate to chat with friend
class FriendsPage extends StatefulWidget {
  const FriendsPage({super.key});

  @override
  State<FriendsPage> createState() => _FriendsPageState();
}

class _FriendsPageState extends State<FriendsPage> {
  final _friendService = FriendService.instance;
  final _meshService = BleMeshService.instance;
  final _addFriendController = TextEditingController();
  final _nicknameController = TextEditingController();

  bool _isInitializing = true;
  StreamSubscription? _directMessageSubscription;

  // Theme colors
  static const Color primaryBlue = Color(0xFF5396FF);
  static const Color primaryRed = Color(0xFFFF6565);
  static const Color bgLight = Color(0xFFF5F7FA);
  static const Color textDark = Color(0xFF2C3E50);
  static const Color textLight = Color(0xFF7F8C8D);
  static const Color successGreen = Color(0xFF27AE60);

  @override
  void initState() {
    super.initState();
    _initialize();
    _friendService.addListener(_onFriendUpdate);
  }

  Future<void> _initialize() async {
    try {
      // Initialize mesh service first if not done
      if (!_meshService.isInitialized) {
        await _meshService.init();
      }

      // Initialize friend service with peer ID
      // FriendService now handles mesh listeners internally
      if (!_friendService.isInitialized && _meshService.peerId != null) {
        await _friendService.init(_meshService.peerId!);
      }

      // Listen for incoming direct messages and forward to FriendService
      _directMessageSubscription = _meshService.directMessageStream.listen((
        msg,
      ) async {
        // Find which friend sent this message
        final senderFriendCode = _findFriendByHash(msg.senderId);

        if (senderFriendCode != null) {
          // Convert MeshMessage to DirectMessage
          final directMsg = DirectMessage(
            id: msg.id,
            senderId: senderFriendCode,
            receiverId: _friendService.myFriendCode ?? '',
            content: msg.content,
            timestamp: msg.timestamp,
            isMe: false,
          );
          await _friendService.addReceivedMessage(directMsg);
        }
      });
    } catch (e) {
      debugPrint('Failed to initialize: $e');
    }

    if (mounted) {
      setState(() => _isInitializing = false);
    }
  }

  /// Find a friend by their sender ID hash
  String? _findFriendByHash(String senderId) {
    for (final friend in _friendService.friends) {
      final friendHash = FriendService.friendCodeToHash(friend.id);
      final friendHashHex = friendHash.toRadixString(16).padLeft(4, '0');

      if (senderId == friendHashHex) {
        return friend.id;
      }
    }
    return null;
  }

  @override
  void dispose() {
    _directMessageSubscription?.cancel();
    _friendService.removeListener(_onFriendUpdate);
    _addFriendController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  void _onFriendUpdate() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializing) {
      return Scaffold(
        backgroundColor: bgLight,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 1,
          title: const Text('Friends'),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final friends = _friendService.friends;

    return Scaffold(
      backgroundColor: bgLight,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        title: const Text(
          'Friends',
          style: TextStyle(color: textDark, fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: textDark),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add, color: primaryBlue),
            onPressed: _showAddFriendDialog,
            tooltip: 'Add Friend',
          ),
        ],
      ),
      body: friends.isEmpty ? _buildEmptyState() : _buildFriendsList(friends),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddFriendDialog,
        backgroundColor: primaryBlue,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add),
        label: const Text('Add Friend'),
      ),
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
              Icons.people_outline,
              size: 100,
              color: textLight.withOpacity(0.3),
            ),
            const SizedBox(height: 24),
            const Text(
              'No Friends Yet',
              style: TextStyle(
                color: textDark,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Add friends using their friend code to start chatting via Bluetooth mesh',
              textAlign: TextAlign.center,
              style: TextStyle(color: textLight, fontSize: 15, height: 1.4),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _showAddFriendDialog,
              icon: const Icon(Icons.person_add),
              label: const Text('Add Your First Friend'),
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFriendsList(List<Friend> friends) {
    final onlineFriends = friends.where((f) => f.isOnline).toList();
    final offlineFriends = friends.where((f) => !f.isOnline).toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Online friends section
        if (onlineFriends.isNotEmpty) ...[
          _buildSectionHeader('Online', onlineFriends.length, successGreen),
          const SizedBox(height: 8),
          ...onlineFriends.map((f) => _buildFriendTile(f)),
          const SizedBox(height: 20),
        ],

        // Offline friends section
        if (offlineFriends.isNotEmpty) ...[
          _buildSectionHeader('Offline', offlineFriends.length, textLight),
          const SizedBox(height: 8),
          ...offlineFriends.map((f) => _buildFriendTile(f)),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(String title, int count, Color color) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(
          '$title ($count)',
          style: TextStyle(
            color: textLight,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildFriendTile(Friend friend) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openChat(friend),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                // Avatar with online indicator
                Stack(
                  children: [
                    CircleAvatar(
                      radius: 26,
                      backgroundColor: primaryBlue.withOpacity(0.1),
                      child: Text(
                        friend.nickname.isNotEmpty
                            ? friend.nickname[0].toUpperCase()
                            : '?',
                        style: TextStyle(
                          color: primaryBlue,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (friend.isOnline)
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: successGreen,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),

                const SizedBox(width: 14),

                // Friend info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              friend.nickname,
                              style: const TextStyle(
                                color: textDark,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (friend.unreadCount > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: primaryBlue,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '${friend.unreadCount}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        friend.id,
                        style: TextStyle(
                          color: textLight,
                          fontSize: 13,
                          fontFamily: 'monospace',
                        ),
                      ),
                      if (friend.lastSeen != null && !friend.isOnline)
                        Text(
                          'Last seen: ${_formatLastSeen(friend.lastSeen!)}',
                          style: TextStyle(
                            color: textLight.withOpacity(0.7),
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),

                // Actions
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert, color: textLight),
                  onSelected: (action) => _handleFriendAction(action, friend),
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'rename',
                      child: Row(
                        children: [
                          Icon(Icons.edit, size: 20),
                          SizedBox(width: 10),
                          Text('Rename'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'copy_code',
                      child: Row(
                        children: [
                          Icon(Icons.copy, size: 20),
                          SizedBox(width: 10),
                          Text('Copy Code'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'remove',
                      child: Row(
                        children: [
                          Icon(Icons.delete, size: 20, color: Colors.red),
                          SizedBox(width: 10),
                          Text('Remove', style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openChat(Friend friend) {
    Navigator.pushNamed(context, '/chat', arguments: friend);
  }

  void _handleFriendAction(String action, Friend friend) {
    switch (action) {
      case 'rename':
        _showRenameDialog(friend);
        break;
      case 'copy_code':
        Clipboard.setData(ClipboardData(text: friend.id));
        HapticFeedback.lightImpact();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Copied: ${friend.id}'),
            backgroundColor: successGreen,
          ),
        );
        break;
      case 'remove':
        _showRemoveConfirmation(friend);
        break;
    }
  }

  void _showAddFriendDialog() {
    _addFriendController.clear();
    _nicknameController.clear();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Add Friend',
                style: TextStyle(
                  color: textDark,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Enter your friend\'s code (e.g., ABC-123)',
                style: TextStyle(color: textLight, fontSize: 14),
              ),
              const SizedBox(height: 20),

              // Friend Code Input
              TextField(
                controller: _addFriendController,
                decoration: InputDecoration(
                  labelText: 'Friend Code',
                  hintText: 'ABC-123',
                  filled: true,
                  fillColor: bgLight,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: const Icon(Icons.person_add),
                ),
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]')),
                  LengthLimitingTextInputFormatter(7),
                  _FriendCodeFormatter(),
                ],
              ),

              const SizedBox(height: 16),

              // Nickname Input (optional)
              TextField(
                controller: _nicknameController,
                decoration: InputDecoration(
                  labelText: 'Nickname (optional)',
                  hintText: 'How you\'ll see them',
                  filled: true,
                  fillColor: bgLight,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: const Icon(Icons.badge),
                ),
                textCapitalization: TextCapitalization.words,
                maxLength: 20,
              ),

              const SizedBox(height: 20),

              // Add Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => _addFriend(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Add Friend',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _addFriend(BuildContext dialogContext) async {
    final code = _addFriendController.text.toUpperCase().trim();
    final nickname = _nicknameController.text.trim();

    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a friend code')),
      );
      return;
    }

    // Validate format
    if (!RegExp(r'^[A-Z]{3}-[0-9]{3}$').hasMatch(code)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid code format. Use ABC-123')),
      );
      return;
    }

    final success = await _friendService.addFriend(
      code,
      nickname: nickname.isNotEmpty ? nickname : null,
    );

    if (success) {
      Navigator.pop(dialogContext);
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Added ${nickname.isNotEmpty ? nickname : code}!'),
          backgroundColor: successGreen,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not add friend. Check the code or already added.',
          ),
        ),
      );
    }
  }

  void _showRenameDialog(Friend friend) {
    _nicknameController.text = friend.nickname;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Rename Friend'),
          content: TextField(
            controller: _nicknameController,
            decoration: InputDecoration(
              labelText: 'Nickname',
              filled: true,
              fillColor: bgLight,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
            textCapitalization: TextCapitalization.words,
            maxLength: 20,
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final newName = _nicknameController.text.trim();
                if (newName.isNotEmpty) {
                  await _friendService.updateFriendNickname(friend.id, newName);
                  Navigator.pop(context);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryBlue,
                foregroundColor: Colors.white,
              ),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _showRemoveConfirmation(Friend friend) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Remove Friend'),
          content: Text(
            'Remove ${friend.nickname} from your friends list?\n\n'
            'This will also delete your chat history.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                await _friendService.removeFriend(friend.id);
                Navigator.pop(context);
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Friend removed')));
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryRed,
                foregroundColor: Colors.white,
              ),
              child: const Text('Remove'),
            ),
          ],
        );
      },
    );
  }

  String _formatLastSeen(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) {
      return 'Just now';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else {
      return '${diff.inDays}d ago';
    }
  }
}

/// Formatter for friend codes (auto-insert dash)
class _FriendCodeFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text.toUpperCase().replaceAll('-', '');

    if (text.length <= 3) {
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    } else {
      final formatted = '${text.substring(0, 3)}-${text.substring(3)}';
      return TextEditingValue(
        text: formatted,
        selection: TextSelection.collapsed(offset: formatted.length),
      );
    }
  }
}
