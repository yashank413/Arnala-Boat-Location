import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

void main() {
  runApp(const ArnalaBoatApp());
}

class ArnalaBoatApp extends StatelessWidget {
  const ArnalaBoatApp({super.key});

  @override
  Widget build(BuildContext context) {
    const teal = Color(0xFF087F8C);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Arnala Boat Tracker',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: teal),
        scaffoldBackgroundColor: const Color(0xFFF2F7F7),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
      ),
      home: const BoatTrackingScreen(),
    );
  }
}

class BoatTrackingScreen extends StatefulWidget {
  const BoatTrackingScreen({super.key});

  @override
  State<BoatTrackingScreen> createState() => _BoatTrackingScreenState();
}

class _BoatTrackingScreenState extends State<BoatTrackingScreen>
    with TickerProviderStateMixin {
  static const String baseUrl =
    "https://arnala-boat-location.onrender.com";

  static const LatLng fallbackLocation = LatLng(19.4550, 72.7500);
  static const LatLng arnalaJetty = LatLng(19.4622441, 72.7445625);
  static const LatLng kalikaMataTemple = LatLng(19.4668527, 72.7343621);

  final MapController mapController = MapController();

  late final AnimationController boatPulseController;
  late final AnimationController panelController;

  StreamSubscription<Position>? positionSubscription;
  Timer? refreshTimer;

  LatLng? boatLocation;
  LatLng? previousBoatLocation;
  DateTime? lastLocationUpdate;

  bool isGettingLocation = false;
  bool hasReceivedLocation = false;
  bool isMapReady = false;
  bool isReversed = false;

  double currentZoom = 14;
  String gpsMessage = 'Waiting for boat location';

  @override
  void initState() {
    super.initState();

    boatPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    panelController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    )..forward();

    fetchLatestLocation();

    refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => fetchLatestLocation(),
    );
  }

  Uri apiUri(String path) => Uri.parse('$apiBaseUrl$path');

  Future<void> fetchLatestLocation() async {
    try {
      final response = await http
          .get(apiUri('/latest_location/'))
          .timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) {
        debugPrint('GET latest location: HTTP ${response.statusCode}');
        return;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final lat = data['latitude'];
      final lng = data['longitude'];

      if (lat is! num || lng is! num) {
        debugPrint('Unexpected latest-location response: ${response.body}');
        return;
      }

      final nextLocation = LatLng(lat.toDouble(), lng.toDouble());

      if (!mounted) return;

      setState(() {
        previousBoatLocation = boatLocation;
        boatLocation = nextLocation;
        lastLocationUpdate = DateTime.now();
        hasReceivedLocation = true;
      });
    } catch (e) {
      debugPrint('Fetch latest location failed: $e');
    }
  }

  Future<void> getPhoneLocation() async {
    if (isGettingLocation) return;

    setState(() {
      isGettingLocation = true;
      gpsMessage = 'Finding this device’s location…';
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        throw Exception('Turn on location services on this device.');
      }

      var permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('Location permission was not granted.');
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );

      final response = await http
          .post(
            apiUri('/location/'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'latitude': position.latitude,
              'longitude': position.longitude,
            }),
          )
          .timeout(const Duration(seconds: 15));

      debugPrint('POST location status: ${response.statusCode}');
      debugPrint('POST location response: ${response.body}');

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Django returned HTTP ${response.statusCode}.');
      }

      if (!mounted) return;

      setState(() {
        gpsMessage =
            'Location sent: ${position.latitude.toStringAsFixed(5)}, '
            '${position.longitude.toStringAsFixed(5)}';
      });

      await fetchLatestLocation();
    } on TimeoutException {
      if (mounted) {
        setState(() {
          gpsMessage = 'Request timed out. Check the server and connection.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          gpsMessage = e.toString().replaceFirst('Exception: ', '');
        });
      }
      debugPrint('GPS/API error: $e');
    } finally {
      if (mounted) {
        setState(() => isGettingLocation = false);
      }
    }
  }

  Future<void> startLocationTracking() async {
    if (positionSubscription != null) return;

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() => gpsMessage = 'Turn on location services first.');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        setState(() => gpsMessage = 'Location permission was not granted.');
        return;
      }

      positionSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen(
        (position) async {
          try {
            final response = await http
                .post(
                  apiUri('/location/'),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({
                    'latitude': position.latitude,
                    'longitude': position.longitude,
                  }),
                )
                .timeout(const Duration(seconds: 15));

            debugPrint('Tracking POST: HTTP ${response.statusCode}');
          } catch (e) {
            debugPrint('Tracking POST failed: $e');
          }
        },
        onError: (Object error) {
          debugPrint('GPS stream error: $error');
        },
      );

      if (mounted) {
        setState(() => gpsMessage = 'Live device tracking started.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => gpsMessage = 'Could not start tracking: $e');
      }
    }
  }

  Future<void> stopLocationTracking() async {
    await positionSubscription?.cancel();
    positionSubscription = null;

    if (mounted) {
      setState(() => gpsMessage = 'Live device tracking stopped.');
    }
  }

  String get statusText {
    if (!hasReceivedLocation || lastLocationUpdate == null) {
      return 'Waiting for GPS';
    }

    if (DateTime.now().difference(lastLocationUpdate!).inSeconds > 30) {
      return 'Location may be old';
    }

    return 'Connected';
  }

  Color get statusColor {
    if (!hasReceivedLocation) return Colors.orange;
    if (statusText != 'Connected') return Colors.red;
    return Colors.green;
  }

  String get lastUpdateText {
    if (lastLocationUpdate == null) return 'No update received yet';

    final seconds = DateTime.now().difference(lastLocationUpdate!).inSeconds;
    if (seconds < 5) return 'Updated just now';
    if (seconds < 60) return 'Updated ${seconds}s ago';
    return 'Updated ${seconds ~/ 60}m ago';
  }

  void centerOnBoat() {
    final target = boatLocation ?? fallbackLocation;
    mapController.move(target, currentZoom < 15 ? 15 : currentZoom);
  }

  void zoomMap(double amount) {
    final nextZoom = (currentZoom + amount).clamp(3.0, 19.0);
    mapController.move(mapController.camera.center, nextZoom);
  }

  void rotateMap() {
    setState(() => isReversed = !isReversed);
    mapController.rotate(isReversed ? 180 : 0);
  }

  Marker buildBoatMarker() {
  final location = boatLocation ?? fallbackLocation;

  return Marker(
    point: location,
    width: 76,
    height: 76,
    child: AnimatedBuilder(
      animation: boatPulseController,
      builder: (context, child) {
        final scale = 1 + (boatPulseController.value * 0.12);

        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 60 * scale,
              height: 60 * scale,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF087F8C)
                    .withOpacity(0.12 * (1 - boatPulseController.value)),
              ),
            ),
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.18),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Icon(
                Icons.directions_boat_rounded,
                color: Color(0xFF087F8C),
                size: 30,
              ),
            ),
          ],
        );
      },
    ),
  );
}
  Widget buildMap() {
    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialCenter: arnalaJetty,
        initialZoom: 14,
        onMapReady: () => isMapReady = true,
        onPositionChanged: (position, _) {
          currentZoom = position.zoom;
        },
      ),
      children: [
        TileLayer(
          urlTemplate:
              'https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
          userAgentPackageName: 'com.example.arnala_boat',
        ),
        TileLayer(
          urlTemplate:
              'https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
          userAgentPackageName: 'com.example.arnala_boat',
        ),
        MarkerLayer(
          markers: [
            if (hasReceivedLocation) buildBoatMarker(),
            Marker(
              point: arnalaJetty,
              width: 130,
              height: 58,
              child: const _PlaceMarker(
                icon: Icons.directions_boat_filled,
                label: 'Arnala Jetty',
                color: Colors.cyanAccent,
              ),
            ),
            Marker(
              point: kalikaMataTemple,
              width: 160,
              height: 58,
              child: const _PlaceMarker(
                icon: Icons.temple_hindu,
                label: 'Kalika Mata Temple',
                color: Colors.amberAccent,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget buildHeader() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.96),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.10),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          const CircleAvatar(
            backgroundColor: Color(0xFFE0F2F1),
            child: Icon(Icons.directions_boat_rounded, color: Color(0xFF087F8C)),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Arnala Boat Tracker',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
                SizedBox(height: 3),
                Text(
                  'Arnala Jetty · Live location',
                  style: TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Rotate map',
            onPressed: rotateMap,
            icon: const Icon(Icons.screen_rotation_rounded),
          ),
        ],
      ),
    );
  }

  Widget buildMapControls() {
    return Column(
      children: [
        _MapButton(
          icon: Icons.my_location_rounded,
          tooltip: 'Center on boat',
          onPressed: centerOnBoat,
        ),
        const SizedBox(height: 8),
        _MapButton(
          icon: Icons.add_rounded,
          tooltip: 'Zoom in',
          onPressed: () => zoomMap(1),
        ),
        const SizedBox(height: 8),
        _MapButton(
          icon: Icons.remove_rounded,
          tooltip: 'Zoom out',
          onPressed: () => zoomMap(-1),
        ),
      ],
    );
  }

  Widget buildBoatCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.12),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0F2F1),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.directions_boat_rounded,
                  color: Color(0xFF087F8C),
                  size: 27,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Arnala Boat',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      'Boat GPS status',
                      style: TextStyle(color: Colors.black54, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Row(
                  children: [
                    Icon(Icons.circle, size: 8, color: statusColor),
                    const SizedBox(width: 6),
                    Text(
                      statusText,
                      style: TextStyle(
                        color: statusColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  label: isGettingLocation ? 'Getting GPS…' : 'Send my location',
                  icon: Icons.my_location_rounded,
                  onPressed: isGettingLocation ? null : getPhoneLocation,
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filledTonal(
                tooltip: positionSubscription == null
                    ? 'Start live tracking'
                    : 'Stop live tracking',
                onPressed: positionSubscription == null
                    ? startLocationTracking
                    : stopLocationTracking,
                icon: Icon(
                  positionSubscription == null
                      ? Icons.play_arrow_rounded
                      : Icons.stop_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.access_time_rounded,
                  size: 15, color: Colors.black45),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  lastUpdateText,
                  style: const TextStyle(
                    color: Colors.black54,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              gpsMessage,
              style: const TextStyle(
                color: Colors.black54,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isMobile = constraints.maxWidth < 700;

            if (isMobile) {
              return Stack(
                children: [
                  Positioned.fill(child: buildMap()),
                  Positioned(
                    top: 12,
                    left: 12,
                    right: 12,
                    child: buildHeader(),
                  ),
                  Positioned(
                    right: 14,
                    bottom: 250,
                    child: buildMapControls(),
                  ),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.15),
                        end: Offset.zero,
                      ).animate(CurvedAnimation(
                        parent: panelController,
                        curve: Curves.easeOutCubic,
                      )),
                      child: FadeTransition(
                        opacity: panelController,
                        child: buildBoatCard(),
                      ),
                    ),
                  ),
                ],
              );
            }

            return Row(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(child: buildMap()),
                      Positioned(
                        top: 16,
                        left: 16,
                        right: 16,
                        child: buildHeader(),
                      ),
                      Positioned(
                        right: 16,
                        bottom: 24,
                        child: buildMapControls(),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 370,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Boat details',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 16),
                        buildBoatCard(),
                        const SizedBox(height: 14),
                        const Text(
                          'The boat marker updates when the backend receives '
                          'new GPS coordinates.',
                          style: TextStyle(color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    positionSubscription?.cancel();
    boatPulseController.dispose();
    panelController.dispose();
    super.dispose();
  }
}

class _PlaceMarker extends StatelessWidget {
  const _PlaceMarker({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 28),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            shadows: [Shadow(color: Colors.black, blurRadius: 5)],
          ),
        ),
      ],
    );
  }
}

class _MapButton extends StatelessWidget {
  const _MapButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 5,
      borderRadius: BorderRadius.circular(15),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, color: const Color(0xFF087F8C)),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.my_location_rounded),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF087F8C),
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
        ),
      ),
    );
  }
}