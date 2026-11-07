
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

const String apiBaseUrl =
    'https://arnala-boat-location.onrender.com';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BoatTrackerApp());
}

class BoatTrackerApp extends StatelessWidget {
  const BoatTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Arnala Boat Tracker',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF087F8C),
        useMaterial3: true,
      ),
      home: const TrackerScreen(),
    );
  }
}

class TrackerScreen extends StatefulWidget {
  const TrackerScreen({super.key});

  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen> {
  static const storage = FlutterSecureStorage();

  StreamSubscription<Position>? positionSubscription;

  final tokenController = TextEditingController();

  Position? currentPosition;

  bool isTracking = false;
  bool isSending = false;
  bool isStarting = false;

  String status = 'Not tracking';
  String uploadStatus = 'Waiting';
  String? deviceToken;

  int successfulUploads = 0;

  @override
  void initState() {
    super.initState();
    loadToken();
  }

  Future<void> loadToken() async {
    try {
      final saved =
          await storage.read(key: 'boat_device_token');

      if (!mounted) return;

      setState(() {
        deviceToken = saved;

        if (saved != null && saved.isNotEmpty) {
          tokenController.text = saved;
        }
      });
    } catch (error) {
      if (!mounted) return;
      showMessage('Could not load saved token: $error');
    }
  }

  Future<void> saveToken() async {
    final value = tokenController.text.trim();

    if (value.isEmpty) {
      showMessage('Enter your private device token.');
      return;
    }

    try {
      await storage.write(
        key: 'boat_device_token',
        value: value,
      );

      if (!mounted) return;

      setState(() {
        deviceToken = value;
        status = 'Device token saved';
      });

      showMessage('Private token saved securely.');
    } catch (error) {
      showMessage('Could not save token: $error');
    }
  }

  Future<bool> checkPermissions() async {
    final serviceEnabled =
        await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      showMessage('Please switch ON GPS on your phone.');
      await Geolocator.openLocationSettings();
      return false;
    }

    LocationPermission permission =
        await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      showMessage('Location permission was denied.');
      return false;
    }

    if (permission == LocationPermission.deniedForever) {
      showMessage(
        'Location permission is blocked. Enable it in App Settings.',
      );
      await Geolocator.openAppSettings();
      return false;
    }

    if (permission == LocationPermission.unableToDetermine) {
      showMessage('Unable to determine location permission.');
      return false;
    }

    // Both whileInUse and always are accepted.
    // Start tracking while the app is visible.
    return true;
  }

  Future<void> startTracking() async {
    if (isStarting || isTracking) return;

    if (deviceToken == null || deviceToken!.isEmpty) {
      showMessage('Save your private device token first.');
      return;
    }

    setState(() {
      isStarting = true;
      status = 'Checking GPS permission...';
    });

    try {
      final permitted = await checkPermissions();

      if (!permitted || !mounted) return;

      final settings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 5),
        foregroundNotificationConfig:
            ForegroundNotificationConfig(
          notificationTitle: 'Arnala Boat Tracking Active',
          notificationText:
              'Your boat location is being shared.',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );

      setState(() {
        isTracking = true;
        status = 'Searching for GPS signal...';
        uploadStatus = 'Waiting for first GPS position';
      });

      // Start continuous tracking.
      positionSubscription =
          Geolocator.getPositionStream(
        locationSettings: settings,
      ).listen(
        (Position position) {
          if (!mounted) return;

          setState(() {
            currentPosition = position;
            status = 'GPS connected';
          });

          uploadLocation(position);
        },
        onError: (error) {
          if (!mounted) return;

          setState(() {
            status = 'GPS stream error: $error';
            isTracking = false;
          });

          positionSubscription?.cancel();
          positionSubscription = null;
        },
        cancelOnError: true,
      );

      // Request an immediate GPS fix as well.
      try {
        final firstPosition =
            await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 25),
          ),
        );

        if (!mounted) return;

        setState(() {
          currentPosition = firstPosition;
          status = 'GPS connected';
        });

        uploadLocation(firstPosition);
      } on TimeoutException {
        if (!mounted) return;

        setState(() {
          status = 'GPS signal is taking longer than expected';
          uploadStatus = 'Still searching for GPS';
        });
      }
    } catch (error) {
      if (!mounted) return;

      setState(() {
        isTracking = false;
        status = 'Could not start tracking: $error';
      });

      await positionSubscription?.cancel();
      positionSubscription = null;
    } finally {
      if (mounted) {
        setState(() {
          isStarting = false;
        });
      }
    }
  }

  Future<void> uploadLocation(Position position) async {
    if (isSending || deviceToken == null) return;

    isSending = true;

    try {
      final response = await http
          .post(
            Uri.parse('$apiBaseUrl/location/'),
            headers: {
              'Content-Type': 'application/json',
              'X-Boat-Device-Token': deviceToken!,
            },
            body: jsonEncode({
              'latitude': position.latitude,
              'longitude': position.longitude,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (response.statusCode == 201) {
        setState(() {
          successfulUploads++;
          uploadStatus = 'Location uploaded successfully';
        });
      } else {
        setState(() {
          uploadStatus =
              'Upload failed (${response.statusCode}): ${response.body}';
        });
      }
    } catch (error) {
      if (!mounted) return;

      setState(() {
        uploadStatus = 'Network error: $error';
      });
    } finally {
      isSending = false;
    }
  }

  Future<void> stopTracking() async {
    await positionSubscription?.cancel();
    positionSubscription = null;

    if (!mounted) return;

    setState(() {
      isTracking = false;
      isStarting = false;
      status = 'Tracking stopped';
      uploadStatus = 'Stopped';
    });
  }

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  void dispose() {
    positionSubscription?.cancel();
    tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final position = currentPosition;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Arnala Boat Tracker'),
        backgroundColor:
            Theme.of(context).colorScheme.primaryContainer,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Icon(
            Icons.directions_boat,
            size: 85,
            color: Color(0xFF087F8C),
          ),
          const SizedBox(height: 12),
          const Center(
            child: Text(
              'Boat GPS Control',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 24),

          const Text(
            'Private device token',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),

          TextField(
            controller: tokenController,
            obscureText: true,
            enabled: !isTracking,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Enter your Render device token',
              prefixIcon: Icon(Icons.lock),
            ),
          ),

          const SizedBox(height: 10),

          OutlinedButton.icon(
            onPressed: isTracking ? null : saveToken,
            icon: const Icon(Icons.security),
            label: const Text('Save token securely'),
          ),

          const SizedBox(height: 24),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  const Text(
                    'TRACKING STATUS',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Icon(
                    isTracking ? Icons.gps_fixed : Icons.gps_off,
                    size: 42,
                    color: isTracking
                        ? Colors.green
                        : Colors.grey,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    status,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    uploadStatus,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          if (position != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'CURRENT GPS LOCATION',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Latitude: ${position.latitude}',
                    ),
                    Text(
                      'Longitude: ${position.longitude}',
                    ),
                    Text(
                      'Accuracy: ${position.accuracy.toStringAsFixed(1)} metres',
                    ),
                    Text(
                      'Speed: ${(position.speed * 3.6).toStringAsFixed(1)} km/h',
                    ),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 12),

          Text(
            'Successful uploads: $successfulUploads',
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 24),

          FilledButton.icon(
            onPressed:
                (isTracking || isStarting) ? null : startTracking,
            icon: const Icon(Icons.play_arrow),
            label: Text(
              isStarting
                  ? 'STARTING...'
                  : 'START BOAT TRACKING',
            ),
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 55),
              backgroundColor: Colors.green,
            ),
          ),

          const SizedBox(height: 12),

          OutlinedButton.icon(
            onPressed: isTracking ? stopTracking : null,
            icon: const Icon(Icons.stop),
            label: const Text('STOP TRACKING'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 55),
              foregroundColor: Colors.red,
            ),
          ),

          const SizedBox(height: 20),

          const Text(
            'Keep GPS and mobile data enabled while the boat is operating. Keep the tracking notification active.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
