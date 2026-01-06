import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/friend.dart';
import 'ble_mesh_service.dart';

/// Service for managing friends and direct messages
///
/// Features:
/// - Generate and manage friend code
/// - Add/remove friends
/// - Track online status of friends
/// - Store chat history per friend
/// - Persist data locally
class FriendService extends ChangeNotifier {
  static FriendService? _instance;
  static FriendService get instance {
    _instance ??= FriendService._();
    return _instance!;
  }

  FriendService._();

  // Storage keys
  static const String _friendCodeKey = 'mesh_friend_code';
  static const String _usernameKey = 'mesh_username';
  static const String _friendsListKey = 'mesh_friends_list';
  static const String _messagesKeyPrefix = 'mesh_messages_';

  // State
  String? _myFriendCode;
  String? _myPeerId;
  String? _username;
  bool _isInitialized = false;

  final Map<String, Friend> _friends = {};
  final Map<String, List<DirectMessage>> _chatHistory = {};

  // Subscriptions
  StreamSubscription? _friendCodeDiscoverySubscription;
  StreamSubscription? _friendRequestSubscription;
  Timer? _staleCheckTimer;

  // Getters
  String? get myFriendCode => _myFriendCode;
  String? get myPeerId => _myPeerId;
  String? get username => _username;
  bool get isInitialized => _isInitialized;
  List<Friend> get friends => _friends.values.toList()
    ..sort((a, b) {
      // Online friends first, then by last seen
      if (a.isOnline != b.isOnline) {
        return a.isOnline ? -1 : 1;
      }
      final aTime = a.lastSeen ?? a.addedAt;
      final bTime = b.lastSeen ?? b.addedAt;
      return bTime.compareTo(aTime);
    });

  int get onlineFriendsCount => _friends.values.where((f) => f.isOnline).length;

  // Streams
  final _friendUpdateController = StreamController<Friend>.broadcast();
  final _messageController = StreamController<DirectMessage>.broadcast();
  final _friendCodeController = StreamController<String>.broadcast();

  Stream<Friend> get friendUpdates => _friendUpdateController.stream;
  Stream<DirectMessage> get messageStream => _messageController.stream;
  Stream<String> get friendCodeStream => _friendCodeController.stream;

  // =========================================================================
  // Initialization
  // =========================================================================

  /// Initialize the friend service
  Future<void> init(String peerId) async {
    if (_isInitialized && _myPeerId == peerId) return;

    _myPeerId = peerId;
    _myFriendCode = generateFriendCode(peerId);

    final prefs = await SharedPreferences.getInstance();

    // Load username
    _username = prefs.getString(_usernameKey);

    // Load friends
    await _loadFriends(prefs);

    // Load chat histories
    await _loadAllChatHistories(prefs);

    // Setup BLE mesh listeners for friend detection and auto-add
    _setupMeshListeners();

    // Periodic stale status check (every 10 seconds)
    _staleCheckTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      checkStaleStatuses();
    });

    _isInitialized = true;
    _friendCodeController.add(_myFriendCode!);
    notifyListeners();
  }

  /// Setup listeners for BLE mesh events
  void _setupMeshListeners() {
    final meshService = BleMeshService.instance;

    // Listen for friend code discoveries (from announcements)
    _friendCodeDiscoverySubscription = meshService.friendCodeDiscoveryStream
        .listen((entry) {
          final peerId = entry.key;
          final friendCode = entry.value;

          // Check if this friend code matches any of our friends
          if (isFriend(friendCode)) {
            updateFriendOnlineStatus(
              friendCode,
              isOnline: true,
              detectedNickname: meshService.peers[peerId]?.nickname,
            );
          }
        });

    // Listen for incoming friend requests (auto-add)
    _friendRequestSubscription = meshService.friendRequestStream.listen((
      entry,
    ) async {
      final nickname = entry.key;
      final friendCode = entry.value;

      // Auto-add if not already a friend
      if (!isFriend(friendCode) && friendCode != _myFriendCode) {
        debugPrint('Auto-adding friend from request: $friendCode ($nickname)');
        await addFriend(friendCode, nickname: nickname, isAutoAdd: true);
      }
    });
  }

  /// Generate a 6-character friend code from peer ID
  /// Format: ABC-123 (letters + numbers)
  static String generateFriendCode(String peerId) {
    // Use a hash to generate consistent code
    int hash = 0;
    for (int i = 0; i < peerId.length; i++) {
      hash = ((hash << 5) - hash + peerId.codeUnitAt(i)) & 0x7FFFFFFF;
    }

    // Generate 3 letters
    const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; // No I, O (confusing)
    String letterPart = '';
    int temp = hash;
    for (int i = 0; i < 3; i++) {
      letterPart += letters[temp % letters.length];
      temp ~/= letters.length;
    }

    // Generate 3 numbers
    String numberPart = ((hash >> 10) % 1000).toString().padLeft(3, '0');

    return '$letterPart-$numberPart';
  }

  /// Get peer ID hash from friend code (for matching)
  static int friendCodeToHash(String friendCode) {
    // Simple hash of the friend code for matching
    int hash = 0;
    final normalized = friendCode.toUpperCase().replaceAll('-', '');
    for (int i = 0; i < normalized.length; i++) {
      hash = ((hash << 5) - hash + normalized.codeUnitAt(i)) & 0xFFFF;
    }
    return hash;
  }

  // =========================================================================
  // Username Management
  // =========================================================================

  /// Set the user's display name
  Future<void> setUsername(String name) async {
    _username = name.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_usernameKey, _username!);
    notifyListeners();
  }

  /// Check if username is set
  bool get hasUsername => _username != null && _username!.isNotEmpty;

  // =========================================================================
  // Friend Management
  // =========================================================================

  /// Add a friend by their friend code
  ///
  /// If [isAutoAdd] is false (default), this will broadcast a friend request
  /// so the other device can auto-add us back.
  Future<bool> addFriend(
    String friendCode, {
    String? nickname,
    bool isAutoAdd = false,
  }) async {
    final normalizedCode = friendCode.toUpperCase().trim();

    // Validate format (ABC-123)
    if (!_isValidFriendCode(normalizedCode)) {
      return false;
    }

    // Can't add yourself
    if (normalizedCode == _myFriendCode) {
      return false;
    }

    // Already added?
    if (_friends.containsKey(normalizedCode)) {
      // If already a friend, just mark them online if this is from a request
      if (isAutoAdd) {
        updateFriendOnlineStatus(
          normalizedCode,
          isOnline: true,
          detectedNickname: nickname,
        );
      }
      return false;
    }

    // Create friend entry
    final friend = Friend(
      id: normalizedCode,
      peerId: normalizedCode, // We use friend code as ID until we see them
      nickname: nickname ?? 'User $normalizedCode',
      addedAt: DateTime.now(),
      isOnline:
          isAutoAdd, // If auto-add, they're online (we just heard from them)
    );

    _friends[normalizedCode] = friend;
    await _saveFriends();

    _friendUpdateController.add(friend);
    notifyListeners();

    // If manually adding (not auto-add), broadcast a friend request
    // so the other device can auto-add us back
    if (!isAutoAdd) {
      try {
        await BleMeshService.instance.broadcastFriendRequest(normalizedCode);
        debugPrint('Sent friend request to $normalizedCode');
      } catch (e) {
        debugPrint('Failed to broadcast friend request: $e');
      }
    }

    return true;
  }

  /// Remove a friend
  Future<void> removeFriend(String friendCode) async {
    _friends.remove(friendCode);
    _chatHistory.remove(friendCode);

    // Remove stored messages
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_messagesKeyPrefix$friendCode');

    await _saveFriends();
    notifyListeners();
  }

  /// Update friend's nickname
  Future<void> updateFriendNickname(String friendCode, String nickname) async {
    final friend = _friends[friendCode];
    if (friend != null) {
      friend.nickname = nickname.trim();
      await _saveFriends();
      _friendUpdateController.add(friend);
      notifyListeners();
    }
  }

  /// Check if a peer is a friend
  bool isFriend(String friendCode) {
    return _friends.containsKey(friendCode.toUpperCase());
  }

  /// Get friend by code
  Friend? getFriend(String friendCode) {
    return _friends[friendCode.toUpperCase()];
  }

  // =========================================================================
  // Online Status
  // =========================================================================

  /// Update friend's online status (called when seen in BLE scan)
  void updateFriendOnlineStatus(
    String friendCode, {
    bool isOnline = true,
    String? detectedNickname,
  }) {
    final friend = _friends[friendCode.toUpperCase()];
    if (friend != null) {
      final wasOnline = friend.isOnline;
      friend.isOnline = isOnline;
      friend.lastSeen = DateTime.now();

      // Update nickname if we detected one
      if (detectedNickname != null && detectedNickname.isNotEmpty) {
        friend.nickname = detectedNickname;
      }

      if (wasOnline != isOnline) {
        _friendUpdateController.add(friend);
        notifyListeners();
      }
    }
  }

  /// Mark all friends as offline (called on scan stop/error)
  void markAllOffline() {
    for (final friend in _friends.values) {
      friend.isOnline = false;
    }
    notifyListeners();
  }

  /// Check and update stale friends (haven't seen in 2+ minutes)
  void checkStaleStatuses() {
    final now = DateTime.now();
    bool changed = false;

    for (final friend in _friends.values) {
      if (friend.isOnline && friend.lastSeen != null) {
        if (now.difference(friend.lastSeen!) > const Duration(minutes: 2)) {
          friend.isOnline = false;
          changed = true;
        }
      }
    }

    if (changed) notifyListeners();
  }

  // =========================================================================
  // Direct Messages
  // =========================================================================

  /// Get chat history with a friend
  List<DirectMessage> getChatHistory(String friendCode) {
    return _chatHistory[friendCode.toUpperCase()] ?? [];
  }

  /// Add a received message
  Future<void> addReceivedMessage(DirectMessage message) async {
    final friendCode = message.senderId.toUpperCase();

    // Only accept messages from friends
    if (!isFriend(friendCode)) {
      debugPrint('Ignoring message from non-friend: $friendCode');
      return;
    }

    _chatHistory.putIfAbsent(friendCode, () => []);
    _chatHistory[friendCode]!.add(message);

    // Increment unread count
    final friend = _friends[friendCode];
    if (friend != null) {
      friend.unreadCount++;
      _friendUpdateController.add(friend);
    }

    await _saveChatHistory(friendCode);
    _messageController.add(message);
    notifyListeners();
  }

  /// Add a sent message
  Future<void> addSentMessage(DirectMessage message) async {
    final friendCode = message.receiverId.toUpperCase();

    _chatHistory.putIfAbsent(friendCode, () => []);
    _chatHistory[friendCode]!.add(message);

    await _saveChatHistory(friendCode);
    _messageController.add(message);
    notifyListeners();
  }

  /// Mark messages as read
  Future<void> markAsRead(String friendCode) async {
    final code = friendCode.toUpperCase();
    final friend = _friends[code];

    if (friend != null && friend.unreadCount > 0) {
      friend.unreadCount = 0;
      _friendUpdateController.add(friend);
      notifyListeners();
    }
  }

  /// Update message delivery status
  void updateMessageStatus(String messageId, {bool? delivered, bool? read}) {
    for (final messages in _chatHistory.values) {
      for (int i = 0; i < messages.length; i++) {
        if (messages[i].id == messageId) {
          messages[i] = messages[i].copyWith(
            isDelivered: delivered,
            isRead: read,
          );
          notifyListeners();
          return;
        }
      }
    }
  }

  // =========================================================================
  // Persistence
  // =========================================================================

  Future<void> _loadFriends(SharedPreferences prefs) async {
    final jsonStr = prefs.getString(_friendsListKey);
    if (jsonStr != null) {
      try {
        final List<dynamic> jsonList = json.decode(jsonStr);
        _friends.clear();
        for (final item in jsonList) {
          final friend = Friend.fromJson(item as Map<String, dynamic>);
          friend.isOnline = false; // Reset online status on load
          _friends[friend.id] = friend;
        }
      } catch (e) {
        debugPrint('Error loading friends: $e');
      }
    }
  }

  Future<void> _saveFriends() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = _friends.values.map((f) => f.toJson()).toList();
    await prefs.setString(_friendsListKey, json.encode(jsonList));
  }

  Future<void> _loadAllChatHistories(SharedPreferences prefs) async {
    for (final friendCode in _friends.keys) {
      await _loadChatHistory(prefs, friendCode);
    }
  }

  Future<void> _loadChatHistory(
    SharedPreferences prefs,
    String friendCode,
  ) async {
    final jsonStr = prefs.getString('$_messagesKeyPrefix$friendCode');
    if (jsonStr != null) {
      try {
        final List<dynamic> jsonList = json.decode(jsonStr);
        _chatHistory[friendCode] = jsonList
            .map((item) => DirectMessage.fromJson(item as Map<String, dynamic>))
            .toList();
      } catch (e) {
        debugPrint('Error loading chat history for $friendCode: $e');
      }
    }
  }

  Future<void> _saveChatHistory(String friendCode) async {
    final prefs = await SharedPreferences.getInstance();
    final messages = _chatHistory[friendCode] ?? [];

    // Only keep last 100 messages per friend
    final toSave = messages.length > 100
        ? messages.sublist(messages.length - 100)
        : messages;

    final jsonList = toSave.map((m) => m.toJson()).toList();
    await prefs.setString(
      '$_messagesKeyPrefix$friendCode',
      json.encode(jsonList),
    );
  }

  // =========================================================================
  // Validation
  // =========================================================================

  bool _isValidFriendCode(String code) {
    // Format: ABC-123 (3 letters, dash, 3 numbers)
    final regex = RegExp(r'^[A-Z]{3}-[0-9]{3}$');
    return regex.hasMatch(code);
  }

  /// Clean up resources
  @override
  void dispose() {
    _friendCodeDiscoverySubscription?.cancel();
    _friendRequestSubscription?.cancel();
    _staleCheckTimer?.cancel();
    _friendUpdateController.close();
    _messageController.close();
    _friendCodeController.close();
    super.dispose();
  }
}
