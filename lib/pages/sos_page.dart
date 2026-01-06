import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import '../services/ble_sos_service.dart';

/// SOS Emergency Page
///
/// Features:
/// - Large SOS button with pulsing animation
/// - Double-tap to trigger (prevents accidental activation)
/// - BLE mesh broadcasting to nearby devices
/// - Real-time location sharing
/// - Alert history display
/// - Connection status monitoring
class SosPage extends StatefulWidget {
  const SosPage({super.key});

  @override
  State<SosPage> createState() => _SosPageState();
}

class _SosPageState extends State<SosPage> with SingleTickerProviderStateMixin {
  // Animation
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Service
  final BleSosService _sosService = BleSosService.instance;

  // State
  bool _isSosActive = false;
  bool _isInitializing = true;
  String? _deviceId;
  Position? _lastPosition;
  final List<String> _alertHistory = [];

  // Stream subscriptions
  StreamSubscription? _alertSubscription;
  StreamSubscription? _deviceIdSubscription;
  StreamSubscription? _packetSubscription;

  // Theme colors
  static const Color primaryRed = Color(0xFFFF6565);
  static const Color darkRed = Color(0xFFD32F2F);
  static const Color bgColor = Color(0xFFF8F9FB);
  static const Color cardColor = Colors.white;
  static const Color textDark = Color(0xFF2C3E50);
  static const Color textLight = Color(0xFF7F8C8D);
  static const Color successGreen = Color(0xFF27AE60);

  @override
  void initState() {
    super.initState();
    _initAnimation();
    _initService();
  }

  void _initAnimation() {
    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  Future<void> _initService() async {
    try {
      await _sosService.init();

      // Listen to device ID
      _deviceIdSubscription = _sosService.deviceIdStream.listen((id) {
        if (mounted) setState(() => _deviceId = id);
      });

      // Listen to alerts
      _alertSubscription = _sosService.alertStream.listen((message) {
        if (!mounted) return;

        setState(() {
          _alertHistory.insert(0, message);
          if (_alertHistory.length > 10) _alertHistory.removeLast();
        });

        // Show snackbar
        final isSent = message.contains("SOS SENT");
        final isReceived = message.contains("RECEIVED");

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(
                  isSent ? Icons.check_circle : Icons.warning_amber_rounded,
                  color: Colors.white,
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(message)),
              ],
            ),
            backgroundColor: isSent
                ? successGreen
                : (isReceived ? Colors.redAccent : Colors.black87),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          ),
        );
      });

      // Listen to packets for statistics
      _packetSubscription = _sosService.packetStream.listen((packet) {
        if (mounted) setState(() {});
      });

      // Get initial location
      _updateLocation();

      if (mounted) {
        setState(() {
          _isInitializing = false;
          _deviceId = _sosService.deviceId;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isInitializing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to initialize: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _updateLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (mounted) {
        setState(() => _lastPosition = position);
      }
    } catch (e) {
      debugPrint('Location error: $e');
    }
  }

  Future<void> _handleSosTrigger() async {
    if (_isSosActive) return;

    setState(() => _isSosActive = true);
    HapticFeedback.heavyImpact();

    try {
      await _sosService.sendSos(message: 'SOS');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to send SOS: $e')));
    } finally {
      // Keep active state briefly for visual feedback
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _isSosActive = false);
      });
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _alertSubscription?.cancel();
    _deviceIdSubscription?.cancel();
    _packetSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: _isInitializing ? _buildLoadingState() : _buildMainContent(),
      ),
    );
  }

  Widget _buildLoadingState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Initializing SOS Service...'),
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 24),
          _buildSosButton(),
          const SizedBox(height: 32),
          _buildStatusCard(),
          const SizedBox(height: 24),
          _buildLocationCard(),
          const SizedBox(height: 24),
          if (_alertHistory.isNotEmpty) _buildAlertHistory(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back, color: Colors.black, size: 24),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          const Text(
            'Emergency SOS',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 22,
              color: Colors.black,
            ),
          ),
          IconButton(
            onPressed: () => Navigator.pushNamed(context, '/mesh_chat'),
            icon: const Icon(
              Icons.chat_bubble_outline,
              color: textDark,
              size: 24,
            ),
            tooltip: 'Mesh Chat',
          ),
        ],
      ),
    );
  }

  Widget _buildSosButton() {
    return Center(
      child: Column(
        children: [
          GestureDetector(
            onDoubleTap: _handleSosTrigger,
            child: AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: _isSosActive ? 1.15 : _pulseAnimation.value,
                  child: Container(
                    width: 220,
                    height: 220,
                    decoration: BoxDecoration(
                      color: _isSosActive ? darkRed : primaryRed,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: primaryRed.withOpacity(0.4),
                          blurRadius:
                              32 * (_isSosActive ? 1.5 : _pulseAnimation.value),
                          spreadRadius: _isSosActive ? 10 : 0,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_isSosActive)
                            const Padding(
                              padding: EdgeInsets.only(bottom: 8.0),
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 3,
                                ),
                              ),
                            ),
                          Text(
                            _isSosActive ? 'SENDING' : 'SOS',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: _isSosActive ? 28 : 42,
                              color: Colors.white,
                              letterSpacing: 4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Double tap to activate',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Broadcasts your location via BLE mesh',
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'BLE Mesh Status',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 16,
                color: textDark,
              ),
            ),
            const SizedBox(height: 16),
            _buildStatusRow(
              icon: Icons.bluetooth,
              label: 'Device ID',
              value: _deviceId != null
                  ? _deviceId!.substring(0, 8).toUpperCase()
                  : 'Initializing...',
              color: successGreen,
            ),
            const Divider(height: 24),
            _buildStatusRow(
              icon: Icons.wifi_tethering,
              label: 'Mesh Network',
              value: 'Active',
              color: successGreen,
            ),
            const Divider(height: 24),
            _buildStatusRow(
              icon: Icons.schedule,
              label: 'Last Update',
              value: _formatTime(DateTime.now()),
              color: textLight,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusRow({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: textLight, fontSize: 14),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ],
    );
  }

  Widget _buildLocationCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Current Location',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                    color: textDark,
                  ),
                ),
                IconButton(
                  onPressed: _updateLocation,
                  icon: const Icon(Icons.refresh, size: 20),
                  color: textLight,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_lastPosition != null)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.location_on,
                        color: primaryRed,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${_lastPosition!.latitude.toStringAsFixed(6)}, '
                          '${_lastPosition!.longitude.toStringAsFixed(6)}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14,
                            color: textDark,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Accuracy: ${_lastPosition!.accuracy.toStringAsFixed(0)}m',
                    style: const TextStyle(color: textLight, fontSize: 12),
                  ),
                ],
              )
            else
              const Text(
                'Location unavailable',
                style: TextStyle(color: textLight, fontSize: 14),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlertHistory() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 12),
            child: Text(
              'Recent Alerts',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 16,
                color: textDark,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _alertHistory.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final alert = _alertHistory[index];
                final isSent = alert.contains("SOS SENT");
                final isReceived = alert.contains("RECEIVED");

                return ListTile(
                  leading: Icon(
                    isSent
                        ? Icons.arrow_upward
                        : (isReceived ? Icons.arrow_downward : Icons.info),
                    color: isSent
                        ? successGreen
                        : (isReceived ? primaryRed : textLight),
                  ),
                  title: Text(
                    alert,
                    style: const TextStyle(fontSize: 13),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  dense: true,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }
}
