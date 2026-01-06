import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'pages/sos_page.dart';
import 'pages/ble_mesh_chat_page.dart';
import 'pages/profile_page.dart';
import 'pages/friends_page.dart';
import 'pages/private_chat_page.dart';
import 'models/friend.dart';

/// BLE Mesh App
///
/// A Flutter application for BLE mesh networking with:
/// - SOS Emergency Button (broadcasts location via BLE)
/// - BLE Mesh Chat (offline communication via Bluetooth)
/// - Friend-based private messaging
///
/// Works without internet connection using Bluetooth Low Energy.
void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Set preferred orientations
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Set system UI overlay style
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  runApp(const BLEMeshApp());
}

class BLEMeshApp extends StatelessWidget {
  const BLEMeshApp({super.key});

  // Theme colors
  static const Color primaryBlue = Color(0xFF5396FF);
  static const Color primaryRed = Color(0xFFFF6565);
  static const Color bgLight = Color(0xFFF5F7FA);
  static const Color textDark = Color(0xFF2C3E50);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Mesh',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryBlue,
          brightness: Brightness.light,
        ),
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: textDark,
          elevation: 0,
          centerTitle: true,
        ),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 2,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const HomePage(),
        '/sos': (context) => const SosPage(),
        '/mesh_chat': (context) => const BleMeshChatPage(),
        '/profile': (context) => const ProfilePage(),
        '/friends': (context) => const FriendsPage(),
      },
      onGenerateRoute: (settings) {
        // Handle private chat route with Friend argument
        if (settings.name == '/chat') {
          final friend = settings.arguments as Friend;
          return MaterialPageRoute(
            builder: (context) => PrivateChatPage(friend: friend),
          );
        }
        return null;
      },
    );
  }
}

/// Home Page - Entry point with navigation to SOS and Chat
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static const Color primaryBlue = Color(0xFF5396FF);
  static const Color primaryRed = Color(0xFFFF6565);
  static const Color bgLight = Color(0xFFF5F7FA);
  static const Color textDark = Color(0xFF2C3E50);
  static const Color textLight = Color(0xFF7F8C8D);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgLight,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),

              // Header
              const Text(
                'BLE Mesh',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: textDark,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Offline communication & emergency alerts via Bluetooth',
                style: TextStyle(fontSize: 14, color: textLight),
              ),

              const SizedBox(height: 32),

              // Feature Cards
              Column(
                children: [
                  // SOS Card
                  _buildFeatureCard(
                    context,
                    icon: Icons.sos,
                    iconColor: Colors.white,
                    iconBgColor: primaryRed,
                    title: 'SOS Emergency',
                    description:
                        'Broadcast your location to nearby devices via BLE mesh. Works without internet.',
                    buttonText: 'Open SOS',
                    buttonColor: primaryRed,
                    onPressed: () => Navigator.pushNamed(context, '/sos'),
                  ),

                  const SizedBox(height: 16),

                  // Mesh Chat Card
                  _buildFeatureCard(
                    context,
                    icon: Icons.people_outline,
                    iconColor: Colors.white,
                    iconBgColor: primaryBlue,
                    title: 'Friends & Chat',
                    description:
                        'Message friends via Bluetooth mesh. Add friends using their code and chat when nearby.',
                    buttonText: 'Open Friends',
                    buttonColor: primaryBlue,
                    onPressed: () => Navigator.pushNamed(context, '/friends'),
                  ),

                  const SizedBox(height: 16),

                  // Profile Card
                  _buildFeatureCard(
                    context,
                    icon: Icons.person_outline,
                    iconColor: Colors.white,
                    iconBgColor: const Color(0xFF9B59B6),
                    title: 'My Profile',
                    description:
                        'Set your username and view your friend code for others to add you.',
                    buttonText: 'View Profile',
                    buttonColor: const Color(0xFF9B59B6),
                    onPressed: () => Navigator.pushNamed(context, '/profile'),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              // Info section
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: primaryBlue, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'BLE Mesh uses Bluetooth Low Energy to create a local mesh network. No internet needed!',
                        style: TextStyle(color: textLight, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureCard(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required Color iconBgColor,
    required String title,
    required String description,
    required String buttonText,
    required Color buttonColor,
    required VoidCallback onPressed,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
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
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: iconBgColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: iconColor, size: 24),
              ),
              const Spacer(),
              Icon(Icons.chevron_right, color: textLight),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: textDark,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: TextStyle(fontSize: 13, color: textLight, height: 1.3),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: buttonColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                buttonText,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
