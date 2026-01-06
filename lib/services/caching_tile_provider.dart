import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

/// A tile provider that caches tiles to disk for offline use.
/// 
/// Tiles are stored in the app's cache directory and persist across sessions.
/// When offline, cached tiles are served; when online, new tiles are cached.
class CachingTileProvider extends TileProvider {
  static const String _tileCacheFolder = 'map_tiles';
  static Directory? _cacheDir;
  static bool _initialized = false;

  /// Initialize the cache directory
  static Future<void> initialize() async {
    if (_initialized) return;
    try {
      final appCacheDir = await getApplicationCacheDirectory();
      _cacheDir = Directory('${appCacheDir.path}/$_tileCacheFolder');
      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
      }
      _initialized = true;
      debugPrint('Tile cache initialized at: ${_cacheDir!.path}');
    } catch (e) {
      debugPrint('Failed to initialize tile cache: $e');
    }
  }

  /// Get the cache file path for a tile
  String _getCachePath(TileCoordinates coords) {
    return '${_cacheDir?.path}/${coords.z}_${coords.x}_${coords.y}.png';
  }

  /// Read a tile from cache
  Future<Uint8List?> _readFromCache(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        return await file.readAsBytes();
      }
    } catch (e) {
      debugPrint('Failed to read tile from cache: $e');
    }
    return null;
  }

  /// Save a tile to cache
  Future<void> _saveToCache(String path, Uint8List bytes) async {
    try {
      final file = File(path);
      await file.writeAsBytes(bytes);
    } catch (e) {
      debugPrint('Failed to save tile to cache: $e');
    }
  }

  @override
  ImageProvider getImage(TileCoordinates coords, TileLayer options) {
    return CachingTileImageProvider(
      coords: coords,
      getCachePath: () => _getCachePath(coords),
      readFromCache: _readFromCache,
      saveToCache: _saveToCache,
      urlTemplate: options.urlTemplate!,
    );
  }
}

/// Custom ImageProvider that handles caching logic
class CachingTileImageProvider extends ImageProvider<CachingTileImageProvider> {
  final TileCoordinates coords;
  final String Function() getCachePath;
  final Future<Uint8List?> Function(String) readFromCache;
  final Future<void> Function(String, Uint8List) saveToCache;
  final String urlTemplate;

  CachingTileImageProvider({
    required this.coords,
    required this.getCachePath,
    required this.readFromCache,
    required this.saveToCache,
    required this.urlTemplate,
  });

  @override
  ImageStreamCompleter loadImage(
    CachingTileImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadTileAsync(decode),
      scale: 1.0,
      informationCollector: () => [
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<TileCoordinates>('Coordinates', coords),
      ],
    );
  }

  Future<ui.Codec> _loadTileAsync(ImageDecoderCallback decode) async {
    final cachePath = getCachePath();

    // Try to load from cache first
    final cachedBytes = await readFromCache(cachePath);
    if (cachedBytes != null) {
      debugPrint('Loaded tile from cache: ${coords.z}/${coords.x}/${coords.y}');
      final buffer = await ui.ImmutableBuffer.fromUint8List(cachedBytes);
      return decode(buffer);
    }

    // Not in cache, download from network
    final url = urlTemplate
        .replaceAll('{z}', coords.z.toString())
        .replaceAll('{x}', coords.x.toString())
        .replaceAll('{y}', coords.y.toString());

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'ble_mesh_app/1.0'},
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;

        // Save to cache in background
        saveToCache(cachePath, bytes);
        debugPrint('Downloaded and cached tile: ${coords.z}/${coords.x}/${coords.y}');

        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        return decode(buffer);
      } else {
        throw Exception('Failed to load tile: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Network error loading tile: $e');
      // If network fails, try cache one more time
      final cachedBytes2 = await readFromCache(cachePath);
      if (cachedBytes2 != null) {
        final buffer = await ui.ImmutableBuffer.fromUint8List(cachedBytes2);
        return decode(buffer);
      }
      rethrow;
    }
  }

  @override
  Future<CachingTileImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CachingTileImageProvider &&
        other.coords == coords &&
        other.urlTemplate == urlTemplate;
  }

  @override
  int get hashCode => Object.hash(coords, urlTemplate);
}

/// Pre-cache tiles around a location for offline use
/// Call this when you have internet to cache tiles for later offline use
Future<int> preCacheTilesAroundLocation({
  required double latitude,
  required double longitude,
  int minZoom = 13,
  int maxZoom = 16,
  int radiusTiles = 2,
  void Function(int cached, int total)? onProgress,
}) async {
  await CachingTileProvider.initialize();

  final cacheDir = await getApplicationCacheDirectory();
  final tileDir = Directory('${cacheDir.path}/map_tiles');

  if (!await tileDir.exists()) {
    await tileDir.create(recursive: true);
  }

  int totalTiles = 0;
  int cachedTiles = 0;

  // Calculate total
  for (int z = minZoom; z <= maxZoom; z++) {
    totalTiles += (2 * radiusTiles + 1) * (2 * radiusTiles + 1);
  }

  for (int z = minZoom; z <= maxZoom; z++) {
    final centerX = _lonToTileX(longitude, z);
    final centerY = _latToTileY(latitude, z);

    for (int dx = -radiusTiles; dx <= radiusTiles; dx++) {
      for (int dy = -radiusTiles; dy <= radiusTiles; dy++) {
        final x = centerX + dx;
        final y = centerY + dy;
        final path = '${tileDir.path}/${z}_${x}_$y.png';

        if (!await File(path).exists()) {
          try {
            final url = 'https://tile.openstreetmap.org/$z/$x/$y.png';
            final response = await http.get(
              Uri.parse(url),
              headers: {'User-Agent': 'ble_mesh_app/1.0'},
            ).timeout(const Duration(seconds: 10));

            if (response.statusCode == 200) {
              await File(path).writeAsBytes(response.bodyBytes);
              cachedTiles++;
              onProgress?.call(cachedTiles, totalTiles);
            }
            // Small delay to avoid rate limiting
            await Future.delayed(const Duration(milliseconds: 100));
          } catch (e) {
            debugPrint('Failed to cache tile $z/$x/$y: $e');
          }
        } else {
          cachedTiles++;
          onProgress?.call(cachedTiles, totalTiles);
        }
      }
    }
  }

  debugPrint('Pre-cached $cachedTiles tiles around ($latitude, $longitude)');
  return cachedTiles;
}

/// Convert longitude to tile X coordinate
int _lonToTileX(double lon, int z) {
  return ((lon + 180.0) / 360.0 * (1 << z)).floor();
}

/// Convert latitude to tile Y coordinate
int _latToTileY(double lat, int z) {
  final latRad = lat * math.pi / 180.0;
  final n = 1 << z;
  return ((1.0 - (math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi)) / 2.0 * n).floor();
}

/// Get cache stats
Future<Map<String, dynamic>> getTileCacheStats() async {
  try {
    final cacheDir = await getApplicationCacheDirectory();
    final tileDir = Directory('${cacheDir.path}/map_tiles');

    if (!await tileDir.exists()) {
      return {'tileCount': 0, 'sizeBytes': 0, 'sizeMB': '0.00'};
    }

    int count = 0;
    int size = 0;

    await for (final entity in tileDir.list()) {
      if (entity is File && entity.path.endsWith('.png')) {
        count++;
        size += await entity.length();
      }
    }

    return {
      'tileCount': count,
      'sizeBytes': size,
      'sizeMB': (size / 1024 / 1024).toStringAsFixed(2),
    };
  } catch (e) {
    return {'tileCount': 0, 'sizeBytes': 0, 'sizeMB': '0.00', 'error': e.toString()};
  }
}

/// Clear all cached tiles
Future<void> clearTileCache() async {
  try {
    final cacheDir = await getApplicationCacheDirectory();
    final tileDir = Directory('${cacheDir.path}/map_tiles');

    if (await tileDir.exists()) {
      await tileDir.delete(recursive: true);
      debugPrint('Tile cache cleared');
    }
  } catch (e) {
    debugPrint('Failed to clear tile cache: $e');
  }
}
