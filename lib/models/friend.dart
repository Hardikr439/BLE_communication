/// Friend model for the mesh chat system
class Friend {
  final String id; // Unique friend code (e.g., "ABC-123")
  final String peerId; // Full peer ID (hash)
  String nickname; // Display name
  DateTime addedAt; // When friend was added
  DateTime? lastSeen; // Last time seen in mesh
  bool isOnline; // Currently in BLE range
  int unreadCount; // Unread message count

  Friend({
    required this.id,
    required this.peerId,
    required this.nickname,
    DateTime? addedAt,
    this.lastSeen,
    this.isOnline = false,
    this.unreadCount = 0,
  }) : addedAt = addedAt ?? DateTime.now();

  /// Create from JSON (for persistence)
  factory Friend.fromJson(Map<String, dynamic> json) {
    return Friend(
      id: json['id'] as String,
      peerId: json['peerId'] as String,
      nickname: json['nickname'] as String,
      addedAt: DateTime.parse(json['addedAt'] as String),
      lastSeen: json['lastSeen'] != null
          ? DateTime.parse(json['lastSeen'] as String)
          : null,
      isOnline: json['isOnline'] as bool? ?? false,
      unreadCount: json['unreadCount'] as int? ?? 0,
    );
  }

  /// Convert to JSON (for persistence)
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'peerId': peerId,
      'nickname': nickname,
      'addedAt': addedAt.toIso8601String(),
      'lastSeen': lastSeen?.toIso8601String(),
      'isOnline': isOnline,
      'unreadCount': unreadCount,
    };
  }

  /// Check if friend was seen recently (within 2 minutes)
  bool get isRecentlyActive {
    if (lastSeen == null) return false;
    return DateTime.now().difference(lastSeen!) < const Duration(minutes: 2);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Friend && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// Direct message between friends
class DirectMessage {
  final String id;
  final String senderId; // Friend code of sender
  final String receiverId; // Friend code of receiver
  final String content;
  final DateTime timestamp;
  final bool isMe; // Sent by current user
  final bool isDelivered; // ACK received
  final bool isRead; // Read receipt received
  final int hopCount; // How many hops to reach

  DirectMessage({
    required this.id,
    required this.senderId,
    required this.receiverId,
    required this.content,
    required this.timestamp,
    required this.isMe,
    this.isDelivered = false,
    this.isRead = false,
    this.hopCount = 0,
  });

  DirectMessage copyWith({bool? isDelivered, bool? isRead}) {
    return DirectMessage(
      id: id,
      senderId: senderId,
      receiverId: receiverId,
      content: content,
      timestamp: timestamp,
      isMe: isMe,
      isDelivered: isDelivered ?? this.isDelivered,
      isRead: isRead ?? this.isRead,
      hopCount: hopCount,
    );
  }

  factory DirectMessage.fromJson(Map<String, dynamic> json) {
    return DirectMessage(
      id: json['id'] as String,
      senderId: json['senderId'] as String,
      receiverId: json['receiverId'] as String,
      content: json['content'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      isMe: json['isMe'] as bool,
      isDelivered: json['isDelivered'] as bool? ?? false,
      isRead: json['isRead'] as bool? ?? false,
      hopCount: json['hopCount'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'senderId': senderId,
      'receiverId': receiverId,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'isMe': isMe,
      'isDelivered': isDelivered,
      'isRead': isRead,
      'hopCount': hopCount,
    };
  }
}
