
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'dart:async';

void main() {
  runApp(const ArnalaBoatApp());
}

class ArnalaBoatApp extends StatelessWidget {
  const ArnalaBoatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Arnala Boat Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
        ),
        useMaterial3: true,
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
    with SingleTickerProviderStateMixin {
  bool isReversed = false;
  String gpsMessage = 'GPS not checked yet';
  double currentZoom = 14;
  LatLng? boatLocation;
  LatLng? previousBoatLocation;
  StreamSubscription<Position>? positionSubscription;
  StreamSubscription? locationFetchSubscription;
  late final AnimationController boatAnimationController;
final MapController mapController = MapController();

  
Future<void> getPhoneLocation() async {
   debugPrint('GPS function started');
  try {
    bool serviceEnabled =
        await Geolocator.isLocationServiceEnabled();
    debugPrint('Location service enabled: $serviceEnabled');

    if (!serviceEnabled) {
      setState(() {
        gpsMessage = 'Please turn on phone location services.';
      });
      return;
    }

    LocationPermission permission =
        await Geolocator.checkPermission();
      debugPrint('Location permission: $permission');

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      setState(() {
        gpsMessage = 'Location permission was not granted.';
      });
      return;
    }

    debugPrint('Requesting current GPS position...');
    Position position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
    debugPrint('Latitude: ${position.latitude}');
    debugPrint('Longitude: ${position.longitude}');
    
final response = await http.post(
  Uri.parse('http://192.168.1.46:8000/location/'),
  headers: {
    'Content-Type': 'application/json',
  },
  body: jsonEncode({
    'latitude': position.latitude,
    'longitude': position.longitude,
  }),
);

debugPrint('Django status: ${response.statusCode}');
debugPrint('Django response: ${response.body}');


    if (!mounted) return;

    setState(() {
      gpsMessage =
          'Latitude: ${position.latitude}\n'
          'Longitude: ${position.longitude}';
    });
  } catch (e) {
    if (!mounted) return;
    debugPrint('GPS ERROR: $e');

    setState(() {
      gpsMessage = 'Could not get location. Please try again.';
    });
  }
}

  Future<void> fetchLatestLocation() async {
  try {
    final response = await http.get(
      Uri.parse('http://192.168.1.46:8000/latest_location/'),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);

      debugPrint(
  'Latest boat location: ${data['latitude']}, ${data['longitude']}',
);

      if (!mounted) return;

      final newLocation = LatLng(
  (data['latitude'] as num).toDouble(),
  (data['longitude'] as num).toDouble(),
);

if (boatLocation != newLocation) {
  setState(() {
    previousBoatLocation = boatLocation;
    boatLocation = newLocation;
  });

  if (previousBoatLocation != null) {
    boatAnimationController.forward(from: 0);
  }
}
    } else {
      debugPrint('Failed to fetch location: ${response.statusCode}');
    }
  } catch (e) {
    debugPrint('Error fetching latest location: $e');
  }
}

Future<void> startLocationTracking() async {
  bool serviceEnabled =
      await Geolocator.isLocationServiceEnabled();

  if (!serviceEnabled) {
    debugPrint('Please enable location services.');
    return;
  }

  LocationPermission permission =
      await Geolocator.checkPermission();

  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }

  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    debugPrint('Location permission not granted.');
    return;
  }

  positionSubscription =
      Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
    ),
  ).listen((Position position) async {
    debugPrint('Automatic GPS: ${position.latitude}, ${position.longitude}');

    try {
      final response = await http.post(
        Uri.parse('http://192.168.1.46:8000/location/'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'latitude': position.latitude,
          'longitude': position.longitude,
        }),
      );

      debugPrint('Automatic POST status: ${response.statusCode}');
    } catch (e) {
      debugPrint('Automatic POST error: $e');
    }
  });
}

LatLng get animatedBoatLocation {
  if (previousBoatLocation == null || boatLocation == null) {
    return boatLocation ?? LatLng(19.4550, 72.7500);
  }

  final progress = Curves.easeInOut.transform(
    boatAnimationController.value,
  );

  return LatLng(
    previousBoatLocation!.latitude +
        (boatLocation!.latitude - previousBoatLocation!.latitude) * progress,
    previousBoatLocation!.longitude +
        (boatLocation!.longitude - previousBoatLocation!.longitude) * progress,
  );
}
 @override
void initState() {
  super.initState();
  boatAnimationController = AnimationController(
  vsync: this,
  duration: const Duration(milliseconds: 1500),
)..addListener(() {
    if (mounted) {
      setState(() {});
    }
  });

  fetchLatestLocation();
  startLocationTracking();


  locationFetchSubscription =
      Stream.periodic(const Duration(seconds: 3)).listen((_) {
    if (mounted) {
      fetchLatestLocation();
    }
  });
}
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
  title: const Text('Arnala Boat Tracker'),
  centerTitle: true,
  actions: [
    IconButton(
      icon: const Icon(Icons.screen_rotation),
      tooltip: 'Reverse view',
      onPressed: () {
  setState(() {
    isReversed = !isReversed;
  });

  mapController.rotate(isReversed ? 180 : 0);
},
    ),
  ],
),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              'Arnala ↔ Arnala Killa',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ClipRRect(
  borderRadius: BorderRadius.circular(16),
  child: FlutterMap(
      mapController: mapController,
    
options: MapOptions(
  initialCenter: LatLng(19.4550, 72.7500),
  initialZoom: 14,
  onPositionChanged: (position, hasGesture) {
  currentZoom = position.zoom;
},
),

    children: [
      TileLayer(
        urlTemplate: 'https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
        userAgentPackageName: 'com.example.arnala_boat',
        keepBuffer: 4,
        panBuffer: 1,
      ),
      
TileLayer(
  urlTemplate: 'https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
  userAgentPackageName: 'com.example.arnala_boat',
  keepBuffer: 4,
  panBuffer: 1,
),

      
MarkerLayer(
  markers: [
    // Existing demo boat marker
    Marker(
      point: animatedBoatLocation,
      width: 50,
      height: 50,
      child: Icon(
        Icons.directions_boat,
        size: 40,
        color: Colors.deepOrange,
      ),
    ),

    // Kalika Mata Temple landmark
    Marker(
      point: LatLng(19.4668527, 72.7343621),
      width: 150 * (currentZoom / 14).clamp(0.7, 1.5),
height: 65 * (currentZoom / 14).clamp(0.7, 1.5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.temple_hindu,
            size: 28 * (currentZoom / 14).clamp(0.7, 1.5),
            color: Colors.deepPurple,
          ),
          Text(
            'Kalika Mata Temple',
            style: TextStyle(
              fontSize: 11 * (currentZoom / 14).clamp(0.7, 1.5),
              fontWeight: FontWeight.bold,
              color: Colors.white,
              // backgroundColor: Colors.black87,
            ),
          ),
        ],
      ),
    ),
  
  // Arnala Jetty landmark
Marker(
  point: LatLng(19.4622441, 72.7445625),
  width: 150,
  height: 65,
  child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        Icons.directions_boat,
        size: 32,
        color: Colors.cyanAccent,
      ),
      Text(
        'Arnala Jetty',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: Colors.white,
          // backgroundColor: Colors.black87,
        ),
      ),
    ],
  ),
),
  ],
        ),
      ],
    ),
  ),
),
const SizedBox(height: 16),

  const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.orange),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Live tracking is not connected yet',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
   onPressed: getPhoneLocation,
  icon: const Icon(Icons.my_location),
  label: const Text('Test Phone GPS'),
),
const SizedBox(height: 8),
Text(
  gpsMessage,
  textAlign: TextAlign.center,
),
          ],
        ),
      ),
        );
  }

  @override
void dispose() {
  positionSubscription?.cancel();
  locationFetchSubscription?.cancel();
  boatAnimationController.dispose();
  super.dispose();
}
}