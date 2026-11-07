
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
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
  State<BoatTrackingScreen> createState() =>
      _BoatTrackingScreenState();
}

class _BoatTrackingScreenState extends State<BoatTrackingScreen>
    with TickerProviderStateMixin {
  static const String baseUrl =
      'https://arnala-boat-location.onrender.com';

  static const LatLng arnalaJetty =
      LatLng(19.4622441, 72.7445625);

  static const LatLng kalikaMataTemple =
      LatLng(19.4668527, 72.7343621);

  final MapController mapController = MapController();

  late final AnimationController boatPulseController;
  late final AnimationController panelController;

  Timer? refreshTimer;

  LatLng? boatLocation;
  DateTime? lastLocationUpdate;

  bool hasReceivedLocation = false;
  bool isMapReady = false;
  bool isReversed = false;
  bool isFetching = false;
  bool hasCenteredOnBoat = false;
  bool apiConnected = false;

  double currentZoom = 14;

  String gpsMessage = 'Waiting for boat GPS location';

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
      const Duration(seconds: 3),
      (_) => fetchLatestLocation(),
    );
  }

  Uri apiUri(String path) => Uri.parse('$baseUrl$path');

  DateTime? parseServerTime(dynamic value) {
    if (value == null) return null;

    return DateTime.tryParse(value.toString())?.toLocal();
  }

  Future<void> fetchLatestLocation() async {
    if (isFetching) return;

    isFetching = true;

    try {
      final response = await http
          .get(apiUri('/latest_location/'))
          .timeout(const Duration(seconds: 20));

      if (!mounted) return;

      if (response.statusCode != 200) {
        setState(() {
          apiConnected = false;
          gpsMessage =
              'Server returned HTTP ${response.statusCode}';
        });
        return;
      }

      final data =
          jsonDecode(response.body) as Map<String, dynamic>;

      final lat = data['latitude'];
      final lng = data['longitude'];

      final latitude = lat is num
          ? lat.toDouble()
          : double.tryParse(lat?.toString() ?? '');

      final longitude = lng is num
          ? lng.toDouble()
          : double.tryParse(lng?.toString() ?? '');

      if (latitude == null ||
          longitude == null ||
          !latitude.isFinite ||
          !longitude.isFinite ||
          latitude < -90 ||
          latitude > 90 ||
          longitude < -180 ||
          longitude > 180) {
        setState(() {
          apiConnected = true;
          gpsMessage = 'Waiting for valid GPS coordinates';
        });
        return;
      }

      final nextLocation = LatLng(latitude, longitude);

      // Adjust these keys to match your Django response.
      final serverTime = parseServerTime(
        data['timestamp'] ??
            data['created_at'] ??
            data['updated_at'],
      );

      setState(() {
        boatLocation = nextLocation;
        hasReceivedLocation = true;
        apiConnected = true;

        // Do not treat the time of fetching as GPS time.
        lastLocationUpdate = serverTime;

        gpsMessage = serverTime == null
            ? 'GPS received; update time unavailable'
            : 'Receiving boat GPS coordinates';
      });

      if (isMapReady && !hasCenteredOnBoat) {
        centerOnBoat();
        hasCenteredOnBoat = true;
      }

      debugPrint(
        'Boat location: $latitude, $longitude',
      );
    } on TimeoutException {
      if (mounted) {
        setState(() {
          apiConnected = false;
          gpsMessage = 'Server timeout. Retrying...';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          apiConnected = false;
          gpsMessage = 'Connection failed. Retrying...';
        });
      }

      debugPrint('GPS fetch error: $e');
    } finally {
      isFetching = false;
    }
  }

  String get statusText {
    if (!apiConnected) {
      return 'Connecting';
    }

    if (!hasReceivedLocation) {
      return 'Waiting for GPS';
    }

    if (lastLocationUpdate == null) {
      return 'Time unknown';
    }

    final age =
        DateTime.now().difference(lastLocationUpdate!);

    if (age.inSeconds > 30) {
      return 'GPS outdated';
    }

    return 'Live';
  }

  Color get statusColor {
    switch (statusText) {
      case 'Live':
        return Colors.green;
      case 'GPS outdated':
        return Colors.red;
      default:
        return Colors.orange;
    }
  }

  String get lastUpdateText {
    if (lastLocationUpdate == null) {
      return 'GPS update time unavailable';
    }

    final seconds = DateTime.now()
        .difference(lastLocationUpdate!)
        .inSeconds;

    if (seconds < 0) {
      return 'GPS timestamp is in the future';
    }

    if (seconds < 5) {
      return 'Updated just now';
    }

    if (seconds < 60) {
      return 'Updated ${seconds}s ago';
    }

    if (seconds < 3600) {
      return 'Updated ${seconds ~/ 60}m ago';
    }

    return 'Updated ${seconds ~/ 3600}h ago';
  }

  void centerOnBoat() {
    if (!isMapReady) return;

    final target = boatLocation ?? arnalaJetty;

    mapController.move(
      target,
      currentZoom < 15 ? 15 : currentZoom,
    );
  }

  void zoomMap(double amount) {
    if (!isMapReady) return;

    final nextZoom =
        (currentZoom + amount).clamp(3.0, 19.0).toDouble();

    mapController.move(
      mapController.camera.center,
      nextZoom,
    );
  }

  void rotateMap() {
    if (!isMapReady) return;

    setState(() {
      isReversed = !isReversed;
    });

    mapController.rotate(isReversed ? 180 : 0);
  }

  Marker buildBoatMarker() {
    final location = boatLocation!;

    return Marker(
      point: location,
      width: 76,
      height: 76,
      child: AnimatedBuilder(
        animation: boatPulseController,
        builder: (context, child) {
          final scale =
              1 + (boatPulseController.value * 0.12);

          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 60 * scale,
                height: 60 * scale,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF087F8C)
                      .withValues(
                    alpha: 0.12 *
                        (1 - boatPulseController.value),
                  ),
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
                      color: Colors.black.withValues(
                        alpha: 0.18,
                      ),
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
        onMapReady: () {
          isMapReady = true;

          if (boatLocation != null &&
              !hasCenteredOnBoat) {
            WidgetsBinding.instance
                .addPostFrameCallback((_) {
              if (!mounted) return;

              centerOnBoat();
              hasCenteredOnBoat = true;
            });
          }
        },
        onPositionChanged: (position, _) {
          currentZoom = position.zoom;
        },
      ),
      children: [
        TileLayer(
          urlTemplate:
              'https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
          userAgentPackageName:
              'com.example.arnala_boat',
        ),
        TileLayer(
          urlTemplate:
              'https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
          userAgentPackageName:
              'com.example.arnala_boat',
        ),
        MarkerLayer(
          markers: [
            if (boatLocation != null)
              buildBoatMarker(),
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
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          const CircleAvatar(
            backgroundColor: Color(0xFFE0F2F1),
            child: Icon(
              Icons.directions_boat_rounded,
              color: Color(0xFF087F8C),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  'Arnala Boat Tracker',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  'Arnala Jetty · Boat location',
                  style: TextStyle(
                    color: Colors.black54,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Rotate map',
            onPressed: rotateMap,
            icon: const Icon(
              Icons.screen_rotation_rounded,
            ),
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
    final locationText = boatLocation == null
        ? 'Waiting for GPS coordinates'
        : '${boatLocation!.latitude.toStringAsFixed(5)}, '
            '${boatLocation!.longitude.toStringAsFixed(5)}';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0F2F1),
                  borderRadius:
                      BorderRadius.circular(16),
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
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
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
                      style: TextStyle(
                        color: Colors.black54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withValues(
                    alpha: 0.12,
                  ),
                  borderRadius:
                      BorderRadius.circular(30),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.circle,
                      size: 8,
                      color: statusColor,
                    ),
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
          const SizedBox(height: 18),
          const Row(
            children: [
              Icon(
                Icons.location_on_outlined,
                size: 18,
                color: Color(0xFF087F8C),
              ),
              SizedBox(width: 7),
              Text(
                'Current boat position',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            locationText,
            style: const TextStyle(
              color: Colors.black54,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              const Icon(
                Icons.access_time_rounded,
                size: 16,
                color: Colors.black45,
              ),
              const SizedBox(width: 7),
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
          const SizedBox(height: 10),
          Text(
            gpsMessage,
            style: const TextStyle(
              color: Colors.black54,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                fetchLatestLocation();
              },
              icon: const Icon(
                Icons.refresh_rounded,
              ),
              label: const Text(
                'Refresh boat location',
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
            final isMobile =
                constraints.maxWidth < 700;

            if (isMobile) {
              return Stack(
                children: [
                  Positioned.fill(
                    child: buildMap(),
                  ),
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
                      ).animate(
                        CurvedAnimation(
                          parent: panelController,
                          curve: Curves.easeOutCubic,
                        ),
                      ),
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
                      Positioned.fill(
                        child: buildMap(),
                      ),
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
                    padding:
                        const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Boat details',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight:
                                FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 16),
                        buildBoatCard(),
                        const SizedBox(height: 14),
                        const Text(
                          'The boat marker updates when '
                          'the backend receives new GPS '
                          'coordinates.',
                          style: TextStyle(
                            color: Colors.black54,
                          ),
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
    boatPulseController.dispose();
    panelController.dispose();
    mapController.dispose();
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
        Icon(
          icon,
          color: color,
          size: 28,
        ),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            shadows: [
              Shadow(
                color: Colors.black,
                blurRadius: 5,
              ),
            ],
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
        icon: Icon(
          icon,
          color: const Color(0xFF087F8C),
        ),
      ),
    );
  }
}
