
import 'dart:async';
import 'dart:collection';
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
  final Queue<Map<String, dynamic>> uploadQueue = Queue();

  Timer? recoveryTimer;
  Timer? uploadRetryTimer;

  Position? currentPosition;
  DateTime? lastGpsUpdate;

  bool isTracking = false;
  bool isStarting = false;
  bool isSending = false;
  bool isStreamStarting = false;

  String status = 'Not tracking';
  String uploadStatus = 'Waiting';
  String? deviceToken;

  int successfulUploads = 0;
  int failedUploads = 0;

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
        if (saved != null) {
          tokenController.text = saved;
        }
      });
    } catch (e) {
      showMessage('Could not load token: $e');
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

      showMessage('Token saved securely.');
    } catch (e) {
      showMessage('Could not save token: $e');
    }
  }

  Future<bool> checkPermissions() async {
    final enabled =
        await Geolocator.isLocationServiceEnabled();

    if (!enabled) {
      showMessage('Please turn on phone GPS.');
      await Geolocator.openLocationSettings();
      return false;
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever ||
        permission == LocationPermission.unableToDetermine) {
      showMessage(
        'Location permission is required. Check app settings.',
      );
      await Geolocator.openAppSettings();
      return false;
    }

    return true;
  }

  Future<void> startTracking() async {
    if (isTracking || isStarting) return;

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

      setState(() {
        isTracking = true;
        status = 'Starting continuous tracking...';
        uploadStatus = 'Waiting for GPS';
      });

      // Start a foreground GPS service.
      await startLocationStream();

      // Try to get the first location immediately.
      await getOneLocation();

      // Recovery checks continue while tracking is active.
      recoveryTimer?.cancel();
      recoveryTimer = Timer.periodic(
        const Duration(seconds: 15),
        (_) async {
          if (!isTracking || !mounted) return;

          final lastUpdate = lastGpsUpdate;

          if (lastUpdate == null ||
              DateTime.now().difference(lastUpdate).inSeconds > 20) {
            if (mounted) {
              setState(() {
                status = 'GPS signal interrupted. Recovering...';
              });
            }

            await getOneLocation();
          }

          // If the stream has stopped, try to reconnect.
          if (positionSubscription == null && isTracking) {
            await startLocationStream();
          }
        },
      );

      // Retry pending uploads regularly.
      uploadRetryTimer?.cancel();
      uploadRetryTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => flushUploadQueue(),
      );

    } catch (e) {
      if (mounted) {
        setState(() {
          status = 'Tracking error: $e';
          isTracking = false;
        });
      }

      await stopTimersAndStream();
    } finally {
      if (mounted) {
        setState(() {
          isStarting = false;
        });
      }
    }
  }

  Future<void> startLocationStream() async {
    if (!isTracking || isStreamStarting) return;

    isStreamStarting = true;

    try {
      await positionSubscription?.cancel();
      positionSubscription = null;

      final settings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 5),
        forceLocationManager: false,
        foregroundNotificationConfig:
            const ForegroundNotificationConfig(
          notificationTitle: 'Arnala Boat Tracking Active',
          notificationText: 'Boat GPS tracking is running.',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );

      positionSubscription =
          Geolocator.getPositionStream(
        locationSettings: settings,
      ).listen(
        (Position position) {
          if (!mounted || !isTracking) return;
          receiveLocation(position);
        },
        onError: (error) {
          positionSubscription = null;

          if (!mounted || !isTracking) return;

          setState(() {
            status = 'GPS interrupted. Reconnecting...';
          });

          // Recovery timer will restart the stream.
        },
        cancelOnError: true,
      );

      if (mounted && isTracking) {
        setState(() {
          status = 'GPS stream active';
        });
      }
    } catch (e) {
      positionSubscription = null;

      if (mounted && isTracking) {
        setState(() {
          status = 'GPS stream restart pending: $e';
        });
      }
    } finally {
      isStreamStarting = false;
    }
  }

  Future<void> getOneLocation() async {
    if (!isTracking) return;

    try {
      final position =
          await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 20),
        ),
      );

      if (!mounted || !isTracking) return;

      receiveLocation(position);
    } on TimeoutException {
      if (!mounted || !isTracking) return;

      setState(() {
        status = 'Waiting for GPS signal...';
      });
    } catch (e) {
      if (!mounted || !isTracking) return;

      setState(() {
        status = 'GPS recovery error: $e';
      });
    }
  }

  void receiveLocation(Position position) {
    if (!mounted || !isTracking) return;

    currentPosition = position;
    lastGpsUpdate = DateTime.now();

    // Save every GPS update for upload.
    uploadQueue.add({
      'latitude': position.latitude,
      'longitude': position.longitude,
    });

    // Avoid unlimited memory growth during a long outage.
    while (uploadQueue.length > 500) {
      uploadQueue.removeFirst();
    }

    setState(() {
      status = 'GPS connected';
      uploadStatus = 'Location captured. Uploading...';
    });

    flushUploadQueue();
  }

  Future<void> flushUploadQueue() async {
    if (isSending ||
        !isTracking ||
        deviceToken == null ||
        uploadQueue.isEmpty) {
      return;
    }

    isSending = true;

    try {
      while (uploadQueue.isNotEmpty && isTracking) {
        final location = uploadQueue.first;

        final response = await http
            .post(
              Uri.parse('$apiBaseUrl/location/'),
              headers: {
                'Content-Type': 'application/json',
                'X-Boat-Device-Token': deviceToken!,
              },
              body: jsonEncode(location),
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200 ||
            response.statusCode == 201) {
          uploadQueue.removeFirst();
          successfulUploads++;

          if (mounted) {
            setState(() {
              uploadStatus =
                  'Location uploaded successfully';
            });
          }
        } else {
          failedUploads++;

          if (mounted) {
            setState(() {
              uploadStatus =
                  'Upload failed (${response.statusCode}). Retrying...';
            });
          }

          break;
        }
      }
    } catch (e) {
      failedUploads++;

      if (mounted) {
        setState(() {
          uploadStatus = 'Network unavailable. Retrying...';
        });
      }
    } finally {
      isSending = false;

      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> stopTimersAndStream() async {
    recoveryTimer?.cancel();
    recoveryTimer = null;

    uploadRetryTimer?.cancel();
    uploadRetryTimer = null;

    await positionSubscription?.cancel();
    positionSubscription = null;
  }

  Future<void> stopTracking() async {
    // Prevent new locations from being collected.
    setState(() {
      isTracking = false;
      status = 'Stopping tracking...';
    });

    await stopTimersAndStream();

    if (!mounted) return;

    setState(() {
      isStarting = false;
      status = 'Tracking stopped';
      uploadStatus = uploadQueue.isEmpty
          ? 'Stopped'
          : '${uploadQueue.length} locations waiting to upload';
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
    recoveryTimer?.cancel();
    uploadRetryTimer?.cancel();
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
              hintText: 'Enter your private device token',
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
                    color: isTracking ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(height: 8),
                  Text(status, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(uploadStatus, textAlign: TextAlign.center),
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'CURRENT GPS LOCATION',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    Text('Latitude: ${position.latitude}'),
                    Text('Longitude: ${position.longitude}'),
                    Text(
                      'Accuracy: ${position.accuracy.toStringAsFixed(1)} metres',
                    ),
                    Text(
                      'Speed: ${(position.speed * 3.6).toStringAsFixed(1)} km/h',
                    ),
                    if (lastGpsUpdate != null)
                      Text(
                        'Last GPS update: ${lastGpsUpdate!.toLocal()}',
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
          Text(
            'Failed upload attempts: $failedUploads',
            textAlign: TextAlign.center,
          ),
          Text(
            'Locations waiting to upload: ${uploadQueue.length}',
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 24),

          FilledButton.icon(
            onPressed:
                (isTracking || isStarting) ? null : startTracking,
            icon: const Icon(Icons.play_arrow),
            label: Text(
              isStarting ? 'STARTING...' : 'START BOAT TRACKING',
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
            'Keep GPS enabled and allow the app to run without battery restrictions. Keep the tracking notification active.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
