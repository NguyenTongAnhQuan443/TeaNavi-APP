import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TeaNaviApp());
}

class TeaNaviApp extends StatelessWidget {
  const TeaNaviApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TeaNavi Companion',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F111A),
        primaryColor: const Color(0xFF00E5FF),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFFFFD600),
          surface: Color(0xFF1A1D2E),
        ),
      ),
      home: const NavigationScreen(),
    );
  }
}

class NavigationStep {
  final int direction; // 0 - 11 tương ứng enum ESP32
  final double distance;
  final String streetName;
  final String instruction;
  final LatLng location;
  final int exitNumber;

  NavigationStep({
    required this.direction,
    required this.distance,
    required this.streetName,
    required this.instruction,
    required this.location,
    this.exitNumber = 1,
  });
}

class NavigationScreen extends StatefulWidget {
  const NavigationScreen({super.key});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  // BLE State
  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? txCharacteristic;
  BluetoothCharacteristic? rxCharacteristic;
  bool isScanning = false;
  bool isConnected = false;

  final String serviceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  final String rxUuid = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"; // App ghi vào đây

  // GPS & Map State
  final MapController mapController = MapController();
  LatLng? currentPosition;
  double currentSpeed = 0.0;
  StreamSubscription<Position>? positionStream;

  // Lộ trình & Tìm kiếm
  final TextEditingController searchController = TextEditingController();
  List<LatLng> routePoints = [];
  List<NavigationStep> navSteps = [];
  int currentStepIndex = 0;
  bool isNavigating = false;
  Timer? syncTimer;

  @override
  void initState() {
    super.initState();
    initLocationService();
  }

  @override
  void dispose() {
    positionStream?.cancel();
    syncTimer?.cancel();
    disconnectBle();
    searchController.dispose();
    super.dispose();
  }

  // ==========================================
  // GPS TRACKING & SPEED
  // ==========================================
  Future<void> initLocationService() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    Position pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );

    if (!mounted) return;
    setState(() {
      currentPosition = LatLng(pos.latitude, pos.longitude);
      currentSpeed = max(0, pos.speed * 3.6); // Chuyển m/s sang km/h
    });

    mapController.move(currentPosition!, 16);

    // Lắng nghe di chuyển thời gian thực
    positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3, // Cập nhật mỗi 3 mét
      ),
    ).listen((Position newPos) {
      if (!mounted) return;
      setState(() {
        currentPosition = LatLng(newPos.latitude, newPos.longitude);
        currentSpeed = max(0, newPos.speed * 3.6);
      });

      if (isNavigating && navSteps.isNotEmpty) {
        processNavigationUpdate();
      }
    });
  }

  // ==========================================
  // BLE BLUETOOTH MANAGEMENT
  // ==========================================
  void startScanBle() async {
    if (isScanning) return;
    setState(() => isScanning = true);

    try {
      // 1. Kiểm tra Bluetooth có đang bật không
      if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Vui lòng bật Bluetooth trên điện thoại!')),
        );
        setState(() => isScanning = false);
        return;
      }

      // 2. Lắng nghe kết quả quét trước khi bắt đầu startScan
      var subscription = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult r in results) {
          String name = r.device.platformName.isNotEmpty ? r.device.platformName : r.advertisementData.advName;
          debugPrint(">> Tim thay BLE: '$name' [${r.device.remoteId}]");
          if (name == "TeaNavi_HUD" || name.contains("TeaNavi")) {
            FlutterBluePlus.stopScan();
            connectToDevice(r.device);
            break;
          }
        }
      });

      // 3. Quét tất cả thiết bị xung quanh trong 8 giây
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
      await FlutterBluePlus.isScanning.where((val) => val == false).first;
      subscription.cancel();
    } catch (e) {
      debugPrint("Lỗi quét BLE: $e");
    } finally {
      if (mounted) setState(() => isScanning = false);
    }
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      await device.connect(license: License.nonprofit, autoConnect: false);
      if (!mounted) return;
      setState(() {
        connectedDevice = device;
        isConnected = true;
      });

      List<BluetoothService> services = await device.discoverServices();
      for (var s in services) {
        if (s.uuid.toString().toUpperCase() == serviceUuid) {
          for (var c in s.characteristics) {
            if (c.uuid.toString().toUpperCase() == rxUuid) {
              rxCharacteristic = c;
            }
          }
        }
      }

      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          if (!mounted) return;
          setState(() {
            isConnected = false;
            connectedDevice = null;
            rxCharacteristic = null;
          });
        }
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã kết nối thành công với TeaNavi HUD!')),
      );
    } catch (e) {
      debugPrint("Lỗi kết nối: $e");
    }
  }

  void disconnectBle() async {
    if (connectedDevice != null) {
      await connectedDevice!.disconnect();
      if (!mounted) return;
      setState(() {
        isConnected = false;
        connectedDevice = null;
      });
    }
  }

  // Gửi gói tin sang ESP32: "DIR,DIST,SPEED,LIMIT,EXIT,STREET_NAME"
  void sendNavPacketToHUD({
    required int direction,
    required int distanceMeters,
    required int speedKmH,
    required int speedLimit,
    required int exitNum,
    required String streetName,
  }) {
    if (rxCharacteristic == null || !isConnected) return;

    // Chuẩn hóa không dấu cho tên đường gửi ESP32
    String safeStreet = removeDiacritics(streetName).toUpperCase();
    String packet = "$direction,$distanceMeters,$speedKmH,$speedLimit,$exitNum,$safeStreet\n";

    try {
      rxCharacteristic!.write(utf8.encode(packet), withoutResponse: true);
    } catch (e) {
      debugPrint("Lỗi gửi BLE: $e");
    }
  }

  String removeDiacritics(String str) {
    const withDia = 'àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđÀÁẠẢÃÂẦẤẬẨẪĂẰẮẶẲẴÈÉẸẺẼÊỀẾỆỂỄÌÍỊỈĨÒÓỌỎÕÔỒỐỘỔỖƠỜỚỢỞỠÙÚỤỦŨƯỪỨỰỬỮỲÝỴỶỸĐ';
    const withoutDia = 'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyydAAAAAAAAAAAAAAAAAEEEEEEEEEEEIIIIIOOOOOOOOOOOOOOOOOUUUUUUUUUUUYYYYYD';
    for (int i = 0; i < withDia.length; i++) {
      str = str.replaceAll(withDia[i], withoutDia[i]);
    }
    return str;
  }

  // ==========================================
  // OSRM ROUTING API (HOÀN TOÀN MIỄN PHÍ 100%)
  // ==========================================
  Future<void> searchAndRoute(String query) async {
    if (currentPosition == null) return;

    // 1. Tìm tọa độ điểm đến qua Nominatim OpenStreetMap (Miễn phí)
    final searchUrl = Uri.parse(
      'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(query)}&format=json&limit=1',
    );

    try {
      final res = await http.get(searchUrl, headers: {'User-Agent': 'TeaNaviCompanion/1.0'});
      if (res.statusCode != 200) return;
      final data = json.decode(res.body);
      if (data.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không tìm thấy địa điểm!')),
        );
        return;
      }

      double destLat = double.parse(data[0]['lat']);
      double destLon = double.parse(data[0]['lon']);
      LatLng destination = LatLng(destLat, destLon);

      // 2. Lấy lộ trình Turn-by-Turn từ OSRM (Miễn phí)
      final osrmUrl = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${currentPosition!.longitude},${currentPosition!.latitude};'
        '${destination.longitude},${destination.latitude}'
        '?overview=full&steps=true&geometries=geojson',
      );

      final osrmRes = await http.get(osrmUrl);
      if (osrmRes.statusCode != 200) return;
      final osrmData = json.decode(osrmRes.body);

      if (osrmData['routes'] == null || osrmData['routes'].isEmpty) return;

      final route = osrmData['routes'][0];
      final geometry = route['geometry']['coordinates'] as List;

      if (!mounted) return;
      // Lưu polyline để vẽ bản đồ
      setState(() {
        routePoints = geometry.map((pt) => LatLng(pt[1], pt[0])).toList();
        navSteps = parseOsrmSteps(route['legs'][0]['steps']);
        currentStepIndex = 0;
        isNavigating = true;
      });

      // Bắt đầu chu kỳ đồng bộ dữ liệu mỗi 800ms sang ESP32
      syncTimer?.cancel();
      syncTimer = Timer.periodic(const Duration(milliseconds: 800), (t) {
        if (isNavigating && navSteps.isNotEmpty) {
          processNavigationUpdate();
        }
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bắt đầu lộ trình: ${data[0]['display_name']}')),
      );
    } catch (e) {
      debugPrint("Lỗi OSRM: $e");
    }
  }

  // Ánh xạ Maneuver của OSRM sang 12 Enum NavDirection của TeaNavi
  List<NavigationStep> parseOsrmSteps(List stepsJson) {
    List<NavigationStep> steps = [];
    for (var s in stepsJson) {
      var maneuver = s['maneuver'];
      String type = maneuver['type'] ?? '';
      String modifier = maneuver['modifier'] ?? '';
      int exitNum = maneuver['exit'] ?? 1;

      int dirEnum = 0; // Default NAV_STRAIGHT
      if (type == 'turn') {
        if (modifier == 'slight right') {
          dirEnum = 1;
        } else if (modifier == 'right') {
          dirEnum = 2;
        } else if (modifier == 'sharp right') {
          dirEnum = 3;
        } else if (modifier == 'slight left') {
          dirEnum = 4;
        } else if (modifier == 'left') {
          dirEnum = 5;
        } else if (modifier == 'sharp left') {
          dirEnum = 6;
        } else if (modifier == 'uturn') {
          dirEnum = 7;
        }
      } else if (type == 'roundabout' || type == 'rotary') {
        dirEnum = 10;
      } else if (type == 'fork' || type == 'on ramp') {
        dirEnum = 9;
      } else if (type == 'arrive') {
        dirEnum = 11;
      }

      double dist = (s['distance'] as num).toDouble();
      String name = (s['name'] == null || s['name'].toString().isEmpty) ? "TIEP TUC DI THANG" : s['name'];
      var loc = maneuver['location'];

      steps.add(NavigationStep(
        direction: dirEnum,
        distance: dist,
        streetName: name,
        instruction: s['maneuver']['type'] ?? '',
        location: LatLng(loc[1], loc[0]),
        exitNumber: exitNum,
      ));
    }
    return steps;
  }

  void processNavigationUpdate() {
    if (currentPosition == null || currentStepIndex >= navSteps.length) return;

    NavigationStep step = navSteps[currentStepIndex];

    // Tính khoảng cách từ vị trí hiện tại đến ngã rẽ kế tiếp
    double distToManeuver = Geolocator.distanceBetween(
      currentPosition!.latitude,
      currentPosition!.longitude,
      step.location.latitude,
      step.location.longitude,
    );

    // Nếu đã qua ngã rẽ (< 15 mét), chuyển sang bước tiếp theo
    if (distToManeuver < 15 && currentStepIndex < navSteps.length - 1) {
      currentStepIndex++;
      step = navSteps[currentStepIndex];
    }

    // Gửi gói tin sang ESP32
    sendNavPacketToHUD(
      direction: step.direction,
      distanceMeters: distToManeuver.round(),
      speedKmH: currentSpeed.round(),
      speedLimit: 60, // Giới hạn mặc định 60km/h
      exitNum: step.exitNumber,
      streetName: step.streetName,
    );
  }

  // ==========================================
  // GIAO DIỆN HIỆN ĐẠI (NEON CYBER HUD STYLE)
  // ==========================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF131622),
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.navigation, color: Color(0xFF00E5FF)),
            SizedBox(width: 8),
            Text(
              'TeaNavi Map',
              style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
            ),
          ],
        ),
        actions: [
          // Nút quét và kết nối BLE
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: ActionChip(
              avatar: Icon(
                isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                color: isConnected ? Colors.greenAccent : Colors.grey,
                size: 18,
              ),
              label: Text(
                isConnected ? 'TeaNavi' : (isScanning ? 'Đang quét...' : 'Kết nối HUD'),
                style: TextStyle(
                  color: isConnected ? Colors.greenAccent : Colors.white70,
                  fontSize: 12,
                ),
              ),
              backgroundColor: isConnected ? Colors.green.withValues(alpha: 0.15) : const Color(0xFF222638),
              onPressed: isConnected ? disconnectBle : startScanBle,
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          // 1. Bản đồ OpenStreetMap hiển thị trực quan
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: currentPosition ?? const LatLng(10.7769, 106.7009), // TP.HCM mặc định
              initialZoom: 15.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}@2x.png',
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'com.teaverse.teanavi_map',
              ),
              if (routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: routePoints,
                      strokeWidth: 5.0,
                      color: const Color(0xFF00E5FF),
                    ),
                  ],
                ),
              if (currentPosition != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: currentPosition!,
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.navigation,
                        color: Colors.blueAccent,
                        size: 30,
                      ),
                    ),
                  ],
                ),
            ],
          ),

          // 2. Thanh tìm kiếm điểm đến trên đỉnh
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1D2E).withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.4)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: TextField(
                controller: searchController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Nhập điểm đến (VD: Chợ Bến Thành)...',
                  hintStyle: const TextStyle(color: Colors.white54),
                  border: InputBorder.none,
                  icon: const Icon(Icons.search, color: Color(0xFF00E5FF)),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.arrow_forward, color: Color(0xFF00E5FF)),
                    onPressed: () => searchAndRoute(searchController.text),
                  ),
                ),
                onSubmitted: searchAndRoute,
              ),
            ),
          ),

          // 3. Card điều khiển & Giám sát HUD bên dưới
          Positioned(
            bottom: 24,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF131622).withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF282D44)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Cụm tốc độ GPS
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('TỐC ĐỘ GPS', style: TextStyle(color: Colors.white54, fontSize: 11)),
                      Text(
                        '${currentSpeed.round()}',
                        style: const TextStyle(
                          color: Color(0xFF00E5FF),
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text('KM/H', style: TextStyle(color: Colors.white38, fontSize: 10)),
                    ],
                  ),

                  // Cụm thông tin ngã rẽ
                  if (isNavigating && navSteps.isNotEmpty)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              navSteps[currentStepIndex].streetName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFFFFD600),
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Đang phát Bluetooth sang HUD ESP32...',
                              style: TextStyle(color: Colors.greenAccent.shade200, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    const Expanded(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16.0),
                        child: Text(
                          'Sẵn sàng dẫn đường & truyền BLE sang TeaNavi HUD',
                          style: TextStyle(color: Colors.white60, fontSize: 12),
                        ),
                      ),
                    ),

                  // Nút định vị lại
                  IconButton(
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFF222638),
                    ),
                    icon: const Icon(Icons.my_location, color: Color(0xFF00E5FF)),
                    onPressed: () {
                      if (currentPosition != null) {
                        mapController.move(currentPosition!, 16);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}





