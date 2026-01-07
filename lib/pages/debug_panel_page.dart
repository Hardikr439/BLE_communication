import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/ble_mesh_service.dart';
import '../services/friend_service.dart';

/// Debug panel for understanding BLE mesh signals
///
/// Shows:
/// - Real-time BLE packets (raw hex + parsed)
/// - Discovered peers with friend codes
/// - Pending friend requests
/// - Mesh state and statistics
/// - Live log stream
class DebugPanelPage extends StatefulWidget {
  const DebugPanelPage({super.key});

  @override
  State<DebugPanelPage> createState() => _DebugPanelPageState();
}

class _DebugPanelPageState extends State<DebugPanelPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  final List<DebugPacket> _packets = [];
  final List<String> _logs = [];
  final ScrollController _logScrollController = ScrollController();
  final ScrollController _packetScrollController = ScrollController();

  StreamSubscription? _statusSubscription;
  StreamSubscription? _errorSubscription;
  StreamSubscription? _peerSubscription;
  StreamSubscription? _messageSubscription;
  StreamSubscription? _friendCodeSubscription;
  StreamSubscription? _friendRequestSubscription;
  StreamSubscription? _rawPacketSubscription;

  bool _autoScroll = true;
  bool _showRawHex = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _setupListeners();
    _addLog('Debug panel initialized');
    _addLog('My Peer ID: ${BleMeshService.instance.peerId}');
    _addLog('My Friend Code: ${FriendService.instance.myFriendCode}');
  }

  void _setupListeners() {
    final mesh = BleMeshService.instance;

    _statusSubscription = mesh.statusStream.listen((status) {
      _addLog('[STATUS] $status');
    });

    _errorSubscription = mesh.errorStream.listen((error) {
      _addLog('[ERROR] $error');
    });

    _peerSubscription = mesh.peerDiscoveryStream.listen((peer) {
      final friendCode = mesh.getFriendCodeForPeer(peer.id);
      _addLog(
        '[PEER] Discovered: ${peer.nickname} (${peer.id}) - FC: $friendCode',
      );

      // Create debug packet entry
      _addPacket(
        DebugPacket(
          timestamp: DateTime.now(),
          type: 'ANNOUNCE',
          senderId: peer.id,
          senderNickname: peer.nickname,
          friendCode: friendCode,
          rawHex: null,
          parsed: {
            'type': 'announce',
            'nickname': peer.nickname,
            'friendCode': friendCode ?? 'N/A',
            'isOnline': peer.isOnline,
          },
        ),
      );
    });

    _messageSubscription = mesh.messageStream.listen((msg) {
      _addLog(
        '[MSG] From ${msg.senderNickname}: "${msg.content}" (hops: ${msg.hopCount})',
      );

      _addPacket(
        DebugPacket(
          timestamp: msg.timestamp,
          type: msg.type.name.toUpperCase(),
          senderId: msg.senderId,
          senderNickname: msg.senderNickname,
          friendCode: null,
          rawHex: null,
          parsed: {
            'type': msg.type.name,
            'content': msg.content,
            'hopCount': msg.hopCount,
            'latitude': msg.latitude,
            'longitude': msg.longitude,
          },
        ),
      );
    });

    _friendCodeSubscription = mesh.friendCodeDiscoveryStream.listen((entry) {
      _addLog(
        '[FRIEND_CODE] Peer ${entry.key} has friend code: ${entry.value}',
      );
    });

    _friendRequestSubscription = mesh.friendRequestStream.listen((entry) {
      _addLog('[FRIEND_REQ] From ${entry.key} with code ${entry.value}');

      _addPacket(
        DebugPacket(
          timestamp: DateTime.now(),
          type: 'FRIEND_REQUEST',
          senderId: 'unknown',
          senderNickname: entry.key,
          friendCode: entry.value,
          rawHex: null,
          parsed: {
            'type': 'friendRequest',
            'senderNickname': entry.key,
            'senderFriendCode': entry.value,
          },
        ),
      );
    });

    // Raw packet stream - shows ALL BLE packets including duplicates
    _rawPacketSubscription = mesh.rawPacketStream.listen((packet) {
      String statusInfo = '';
      if (packet.isDuplicate) statusInfo += ' [DUP]';
      if (packet.isFromSelf) statusInfo += ' [SELF]';
      if (packet.error != null) statusInfo += ' [ERR: ${packet.error}]';

      _addLog(
        '[RAW] ${packet.messageTypeName ?? "?"} from 0x${packet.senderIdHash?.toRadixString(16) ?? "?"} TTL:${packet.ttl}$statusInfo',
      );

      // Add raw packet to list (these are the primary source of truth)
      _addPacket(
        DebugPacket(
          timestamp: packet.timestamp,
          type: packet.messageTypeName?.toUpperCase() ?? 'UNKNOWN',
          senderId:
              packet.senderIdHash?.toRadixString(16).padLeft(4, '0') ?? '????',
          senderNickname: null,
          friendCode: null,
          rawHex: packet.hexString,
          parsed: packet.toMap(),
        ),
      );
    });
  }

  void _addLog(String message) {
    final timestamp = DateTime.now().toString().substring(11, 23);
    setState(() {
      _logs.add('[$timestamp] $message');
      if (_logs.length > 500) {
        _logs.removeAt(0);
      }
    });

    if (_autoScroll && _logScrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 50), () {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      });
    }
  }

  void _addPacket(DebugPacket packet) {
    setState(() {
      _packets.insert(0, packet);
      if (_packets.length > 100) {
        _packets.removeLast();
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _logScrollController.dispose();
    _packetScrollController.dispose();
    _statusSubscription?.cancel();
    _errorSubscription?.cancel();
    _peerSubscription?.cancel();
    _messageSubscription?.cancel();
    _friendCodeSubscription?.cancel();
    _friendRequestSubscription?.cancel();
    _rawPacketSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🔧 BLE Debug Panel'),
        backgroundColor: Colors.grey[900],
        foregroundColor: Colors.green,
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.green,
          unselectedLabelColor: Colors.grey,
          indicatorColor: Colors.green,
          tabs: const [
            Tab(icon: Icon(Icons.receipt_long), text: 'Packets'),
            Tab(icon: Icon(Icons.people), text: 'Peers'),
            Tab(icon: Icon(Icons.analytics), text: 'Stats'),
            Tab(icon: Icon(Icons.terminal), text: 'Logs'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              BleMeshService.instance.announcePresence();
              _addLog('[ACTION] Manual presence announcement');
            },
            tooltip: 'Announce Presence',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              setState(() {
                _packets.clear();
                _logs.clear();
              });
              _addLog('[ACTION] Cleared logs and packets');
            },
            tooltip: 'Clear All',
          ),
        ],
      ),
      backgroundColor: Colors.black,
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildPacketsTab(),
          _buildPeersTab(),
          _buildStatsTab(),
          _buildLogsTab(),
        ],
      ),
    );
  }

  Widget _buildPacketsTab() {
    return Column(
      children: [
        // Controls
        Container(
          color: Colors.grey[900],
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              FilterChip(
                label: const Text('Show Raw Hex'),
                selected: _showRawHex,
                onSelected: (v) => setState(() => _showRawHex = v),
                selectedColor: Colors.green.withOpacity(0.3),
                labelStyle: TextStyle(
                  color: _showRawHex ? Colors.green : Colors.grey,
                ),
              ),
              const Spacer(),
              Text(
                '${_packets.length} packets',
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
        // Packet list
        Expanded(
          child: _packets.isEmpty
              ? const Center(
                  child: Text(
                    'No packets received yet...\nWaiting for BLE signals',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  controller: _packetScrollController,
                  itemCount: _packets.length,
                  itemBuilder: (context, index) {
                    final packet = _packets[index];
                    return _buildPacketCard(packet);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildPacketCard(DebugPacket packet) {
    Color typeColor;
    IconData typeIcon;

    switch (packet.type) {
      case 'ANNOUNCE':
        typeColor = Colors.blue;
        typeIcon = Icons.broadcast_on_personal;
        break;
      case 'MESSAGE':
        typeColor = Colors.green;
        typeIcon = Icons.message;
        break;
      case 'DIRECT':
        typeColor = Colors.purple;
        typeIcon = Icons.person;
        break;
      case 'FRIEND_REQUEST':
        typeColor = Colors.orange;
        typeIcon = Icons.person_add;
        break;
      case 'SOS':
        typeColor = Colors.red;
        typeIcon = Icons.warning;
        break;
      default:
        typeColor = Colors.grey;
        typeIcon = Icons.help;
    }

    return Card(
      color: Colors.grey[900],
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ExpansionTile(
        leading: Icon(typeIcon, color: typeColor),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: typeColor.withOpacity(0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                packet.type,
                style: TextStyle(
                  color: typeColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                packet.senderNickname ?? packet.senderId,
                style: const TextStyle(color: Colors.white),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        subtitle: Text(
          packet.timestamp.toString().substring(11, 23),
          style: const TextStyle(color: Colors.grey, fontSize: 11),
        ),
        iconColor: Colors.grey,
        collapsedIconColor: Colors.grey,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.black,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (packet.friendCode != null) ...[
                  _buildInfoRow('Friend Code', packet.friendCode!),
                  const SizedBox(height: 4),
                ],
                _buildInfoRow('Sender ID', packet.senderId),
                const SizedBox(height: 8),
                const Text(
                  'Parsed Data:',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[850],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SelectableText(
                    _formatParsed(packet.parsed),
                    style: const TextStyle(
                      color: Colors.green,
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
                if (_showRawHex && packet.rawHex != null) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Raw Hex:',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey[850],
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SelectableText(
                      packet.rawHex!,
                      style: const TextStyle(
                        color: Colors.amber,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(
            '$label:',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.copy, size: 16),
          color: Colors.grey,
          onPressed: () {
            Clipboard.setData(ClipboardData(text: value));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Copied: $value'),
                duration: const Duration(seconds: 1),
              ),
            );
          },
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ],
    );
  }

  String _formatParsed(Map<String, dynamic> parsed) {
    return parsed.entries.map((e) => '${e.key}: ${e.value}').join('\n');
  }

  Widget _buildPeersTab() {
    final mesh = BleMeshService.instance;
    final peers = mesh.peers.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

    final friendService = FriendService.instance;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // My Info
          _buildSectionCard('My Device', [
            _buildStatRow('Peer ID', mesh.peerId ?? 'N/A'),
            _buildStatRow('Nickname', mesh.nickname ?? 'N/A'),
            _buildStatRow('Friend Code', friendService.myFriendCode ?? 'N/A'),
            _buildStatRow('Username', friendService.username ?? 'Not set'),
          ], color: Colors.blue),
          const SizedBox(height: 16),

          // Discovered Peers
          _buildSectionCard(
            'Discovered Peers (${peers.length})',
            peers.isEmpty
                ? [
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'No peers discovered yet',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    ),
                  ]
                : peers.map((peer) {
                    final friendCode = mesh.getFriendCodeForPeer(peer.id);
                    final isFriend =
                        friendCode != null &&
                        friendService.isFriend(friendCode);

                    return ListTile(
                      dense: true,
                      leading: Icon(
                        peer.isOnline ? Icons.circle : Icons.circle_outlined,
                        color: peer.isOnline ? Colors.green : Colors.grey,
                        size: 12,
                      ),
                      title: Text(
                        '${peer.nickname} ${isFriend ? "⭐" : ""}',
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        'ID: ${peer.id} | FC: ${friendCode ?? "N/A"}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                      trailing: Text(
                        _formatAgo(peer.lastSeen),
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                    );
                  }).toList(),
            color: Colors.green,
          ),
          const SizedBox(height: 16),

          // Friends
          _buildSectionCard(
            'Friends (${friendService.friends.length})',
            friendService.friends.isEmpty
                ? [
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'No friends added yet',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    ),
                  ]
                : friendService.friends.map((friend) {
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        friend.isOnline ? Icons.circle : Icons.circle_outlined,
                        color: friend.isOnline ? Colors.green : Colors.grey,
                        size: 12,
                      ),
                      title: Text(
                        friend.nickname,
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        'Code: ${friend.id}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                      trailing: Text(
                        friend.lastSeen != null
                            ? _formatAgo(friend.lastSeen!)
                            : 'Never seen',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                    );
                  }).toList(),
            color: Colors.purple,
          ),
        ],
      ),
    );
  }

  Widget _buildStatsTab() {
    final stats = BleMeshService.instance.getStats();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _buildSectionCard('Network Statistics', [
            _buildStatRow('Active Peers', '${stats['activePeers']}'),
            _buildStatRow('Total Peers Seen', '${stats['totalPeers']}'),
            _buildStatRow('Messages in Cache', '${stats['totalMessages']}'),
            _buildStatRow('Cache Size', '${stats['cacheSize']}'),
            _buildStatRow('Queued Relays', '${stats['queuedRelays']}'),
          ], color: Colors.cyan),
          const SizedBox(height: 16),
          _buildSectionCard('Message Counts', [
            _buildStatRow('Messages Sent', '${stats['messagesSent']}'),
            _buildStatRow('Messages Received', '${stats['messagesReceived']}'),
            _buildStatRow('Messages Relayed', '${stats['messagesRelayed']}'),
          ], color: Colors.orange),
          const SizedBox(height: 16),
          _buildSectionCard('BLE Status', [
            _buildStatRow(
              'Initialized',
              '${BleMeshService.instance.isInitialized}',
            ),
            _buildStatRow('Scanning', '${BleMeshService.instance.isScanning}'),
          ], color: Colors.teal),
          const SizedBox(height: 16),

          // Test Actions
          _buildSectionCard('Test Actions', [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    BleMeshService.instance.announcePresence();
                    _addLog('[TEST] Manual announcement sent');
                  },
                  icon: const Icon(Icons.broadcast_on_personal, size: 16),
                  label: const Text('Announce'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    BleMeshService.instance.sendMessage('Test message');
                    _addLog('[TEST] Test message sent');
                  },
                  icon: const Icon(Icons.send, size: 16),
                  label: const Text('Send Test Msg'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                  ),
                ),
              ],
            ),
          ], color: Colors.amber),
        ],
      ),
    );
  }

  Widget _buildSectionCard(
    String title,
    List<Widget> children, {
    required Color color,
  }) {
    return Card(
      color: Colors.grey[900],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Text(
              title,
              style: TextStyle(color: color, fontWeight: FontWeight.bold),
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          SelectableText(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogsTab() {
    return Column(
      children: [
        // Controls
        Container(
          color: Colors.grey[900],
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              FilterChip(
                label: const Text('Auto-scroll'),
                selected: _autoScroll,
                onSelected: (v) => setState(() => _autoScroll = v),
                selectedColor: Colors.green.withOpacity(0.3),
                labelStyle: TextStyle(
                  color: _autoScroll ? Colors.green : Colors.grey,
                ),
              ),
              const Spacer(),
              Text(
                '${_logs.length} logs',
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
        // Logs
        Expanded(
          child: Container(
            color: Colors.black,
            child: ListView.builder(
              controller: _logScrollController,
              padding: const EdgeInsets.all(8),
              itemCount: _logs.length,
              itemBuilder: (context, index) {
                final log = _logs[index];
                Color color = Colors.grey;

                if (log.contains('[ERROR]')) {
                  color = Colors.red;
                } else if (log.contains('[PEER]')) {
                  color = Colors.blue;
                } else if (log.contains('[MSG]')) {
                  color = Colors.green;
                } else if (log.contains('[FRIEND')) {
                  color = Colors.orange;
                } else if (log.contains('[STATUS]')) {
                  color = Colors.cyan;
                } else if (log.contains('[ACTION]') || log.contains('[TEST]')) {
                  color = Colors.yellow;
                }

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: SelectableText(
                    log,
                    style: TextStyle(
                      color: color,
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  String _formatAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) {
      return '${diff.inSeconds}s ago';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else {
      return '${diff.inHours}h ago';
    }
  }
}

/// Represents a debug packet for display
class DebugPacket {
  final DateTime timestamp;
  final String type;
  final String senderId;
  final String? senderNickname;
  final String? friendCode;
  final String? rawHex;
  final Map<String, dynamic> parsed;

  DebugPacket({
    required this.timestamp,
    required this.type,
    required this.senderId,
    this.senderNickname,
    this.friendCode,
    this.rawHex,
    required this.parsed,
  });
}
