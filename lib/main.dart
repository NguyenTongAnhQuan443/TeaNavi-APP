import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ),
  );
  runApp(const TeaNaviApp());
}

class TeaNaviApp extends StatelessWidget {
  const TeaNaviApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TeaNavi Companion',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF7F8FA),
        primaryColor: const Color(0xFF007AFF),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF007AFF),
          secondary: Color(0xFF34C759),
          surface: Colors.white,
          onSurface: Color(0xFF1C1C1E),
        ),
        fontFamily: '.SF Pro Text',
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF000000),
        primaryColor: const Color(0xFF0A84FF),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF0A84FF),
          secondary: Color(0xFF30D158),
          surface: Color(0xFF1C1C1E),
          onSurface: Colors.white,
        ),
        fontFamily: '.SF Pro Text',
        useMaterial3: true,
      ),
      home: const NavigationScreen(),
    );
  }
}

class SearchResultPlace {
  final String title;
  final String subtitle;
  final LatLng location;

  SearchResultPlace({
    required this.title,
    required this.subtitle,
    required this.location,
  });
}

class NavigationStep {
  final int direction;
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

class QuickPlaceItem {
  final String title;
  final IconData icon;
  final String query;

  const QuickPlaceItem({
    required this.title,
    required this.icon,
    required this.query,
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
  BluetoothCharacteristic? rxCharacteristic;
  bool isScanning = false;
  bool isConnected = false;

  final String serviceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  final String rxUuid = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";

  // GPS & Map State
  final MapController mapController = MapController();
  LatLng? currentPosition;
  double currentSpeed = 0.0;
  double currentHeading = 0.0;
  StreamSubscription<Position>? positionStream;

  // Lộ trình & Điểm đi / Điểm đến
  final TextEditingController startController = TextEditingController();
  final TextEditingController destController = TextEditingController();
  LatLng? originPoint;
  String originName = "Vị trí của bạn";
  LatLng? destPoint;
  String destinationName = "";

  bool isSelectingOrigin = false;
  bool isRouteStepsExpanded = false; // Bật tắt danh sách toàn bộ các ngã rẽ chi tiết

  // Danh sách gợi ý tìm kiếm (Autocomplete Suggestions)
  List<SearchResultPlace> searchSuggestions = [];
  bool isSearchingSuggestions = false;
  Timer? debounceTimer;
  bool activeSearchForOrigin = false;

  List<LatLng> routePoints = [];
  List<NavigationStep> navSteps = [];
  int currentStepIndex = 0;
  bool isNavigating = false;
  bool isLoadingRoute = false;
  double totalRouteDistanceKm = 0.0;
  Timer? syncTimer;
  Timer? idleHudTimer;

  final List<QuickPlaceItem> quickPlaces = const [
    QuickPlaceItem(
      title: 'Cây xăng',
      icon: Icons.local_gas_station_rounded,
      query: 'cây xăng gần nhất',
    ),
    QuickPlaceItem(
      title: 'Quán ăn',
      icon: Icons.restaurant_rounded,
      query: 'quán ăn gần đây',
    ),
    QuickPlaceItem(
      title: 'Bãi xe',
      icon: Icons.local_parking_rounded,
      query: 'bãi đỗ xe',
    ),
    QuickPlaceItem(
      title: 'Cà phê',
      icon: Icons.local_cafe_rounded,
      query: 'quán cà phê gần đây',
    ),
    QuickPlaceItem(title: 'Nhà', icon: Icons.home_rounded, query: 'Nhà'),
    QuickPlaceItem(
      title: 'Công ty',
      icon: Icons.work_rounded,
      query: 'Công ty',
    ),
  ];

  @override
  void initState() {
    super.initState();
    startController.text = "Vị trí của bạn";
    initLocationService();
  }

  @override
  void dispose() {
    debounceTimer?.cancel();
    positionStream?.cancel();
    syncTimer?.cancel();
    idleHudTimer?.cancel();
    disconnectBle();
    startController.dispose();
    destController.dispose();
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
    LatLng actualPos = LatLng(pos.latitude, pos.longitude);

    setState(() {
      currentPosition = actualPos;
      currentSpeed = max(0, pos.speed * 3.6);
      currentHeading = pos.heading;
      originPoint ??= actualPos;
    });

    mapController.move(currentPosition!, 16);

    positionStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 2,
          ),
        ).listen((Position newPos) {
          if (!mounted) return;
          setState(() {
            currentPosition = LatLng(newPos.latitude, newPos.longitude);
            currentSpeed = max(0, newPos.speed * 3.6);
            if (newPos.heading > 0) {
              currentHeading = newPos.heading;
            }
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
      if (await FlutterBluePlus.adapterState.first !=
          BluetoothAdapterState.on) {
        if (!mounted) return;
        _showToast('Vui lòng bật Bluetooth trên điện thoại!');
        setState(() => isScanning = false);
        return;
      }

      var subscription = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult r in results) {
          String name = r.device.platformName.isNotEmpty
              ? r.device.platformName
              : r.advertisementData.advName;
          if (name == "TeaNavi_HUD" || name.contains("TeaNavi")) {
            FlutterBluePlus.stopScan();
            connectToDevice(r.device);
            break;
          }
        }
      });

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
        if (s.uuid.toString().toUpperCase().contains('6E400001')) {
          for (var c in s.characteristics) {
            if (c.uuid.toString().toUpperCase().contains('6E400002')) {
              rxCharacteristic = c;
            }
          }
        }
      }

      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          if (!mounted) return;
          idleHudTimer?.cancel();
          setState(() {
            isConnected = false;
            connectedDevice = null;
            rxCharacteristic = null;
          });
          _showToast('Đã ngắt kết nối với HUD');
        }
      });

      if (!mounted) return;
      _showToast('Đã kết nối thành công với TeaNavi HUD!');

      // Bắt đầu timer gửi sync định kỳ cho HUD kể cả khi chưa dẫn đường (Hiển thị tốc độ & đồng hồ)
      idleHudTimer?.cancel();
      idleHudTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (isConnected && !isNavigating) {
          sendIdlePacketToHUD();
        }
      });
      sendIdlePacketToHUD();
    } catch (e) {
      debugPrint("Lỗi kết nối: $e");
    }
  }

  void disconnectBle() async {
    idleHudTimer?.cancel();
    if (connectedDevice != null) {
      await connectedDevice!.disconnect();
      if (!mounted) return;
      setState(() {
        isConnected = false;
        connectedDevice = null;
      });
      _showToast('Đã ngắt kết nối Bluetooth');
    }
  }

  void _showToast(String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void sendNavPacketToHUD({
    required int direction,
    required int distanceMeters,
    required int speedKmH,
    required int speedLimit,
    required int exitNum,
    required String streetName,
    String? timeStr,
  }) {
    if (rxCharacteristic == null || !isConnected) return;
    String safeStreet = removeDiacritics(streetName).toUpperCase();
    
    // Lấy giờ hiện tại "HH:mm" nếu chưa truyền
    String time = timeStr ??
        "${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}";

    // Format: "DIR,DIST,SPEED,LIMIT,EXIT,STREET_NAME,TIME\n"
    String packet =
        "$direction,$distanceMeters,$speedKmH,$speedLimit,$exitNum,$safeStreet,$time\n";

    try {
      rxCharacteristic!.write(utf8.encode(packet), withoutResponse: true);
    } catch (e) {
      debugPrint("Lỗi gửi BLE: $e");
    }
  }

  void sendIdlePacketToHUD() {
    if (rxCharacteristic == null || !isConnected) return;
    // Khi chưa dẫn đường: Gửi tốc độ GPS, giới hạn 50, và giờ thực
    String time =
        "${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}";
    String packet =
        "0,0,${currentSpeed.round()},50,1,TEANAVI READY,$time\n";

    try {
      rxCharacteristic!.write(utf8.encode(packet), withoutResponse: true);
    } catch (e) {
      debugPrint("Lỗi gửi idle BLE: $e");
    }
  }

  String removeDiacritics(String str) {
    const withDia =
        'àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđÀÁẠẢÃÂẦẤẬẨẪĂẰẮẶẲẴÈÉẸẺẼÊỀẾỆỂỄÌÍỊỈĨÒÓỌỎÕÔỒỐỘỔỖƠỜỚỢỞỠÙÚỤỦŨƯỪỨỰỬỮỲÝỴỶỸĐ';
    const withoutDia =
        'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyydAAAAAAAAAAAAAAAAAEEEEEEEEEEEIIIIIOOOOOOOOOOOOOOOOOUUUUUUUUUUUYYYYYD';
    for (int i = 0; i < withDia.length; i++) {
      str = str.replaceAll(withDia[i], withoutDia[i]);
    }
    return str;
  }

  // ==========================================
  // REAL-TIME AUTOCOMPLETE SEARCH (HIỂN THỊ DANH SÁCH KẾT QUẢ)
  // ==========================================
  void onSearchTextChanged(String query, {required bool forOrigin}) {
    activeSearchForOrigin = forOrigin;
    debounceTimer?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        searchSuggestions.clear();
        isSearchingSuggestions = false;
      });
      return;
    }

    debounceTimer = Timer(const Duration(milliseconds: 350), () {
      fetchLocationSuggestions(query.trim());
    });
  }

  Future<void> fetchLocationSuggestions(String query) async {
    setState(() => isSearchingSuggestions = true);

    LatLng anchor = currentPosition ?? const LatLng(10.8220, 106.6875);
    if (anchor.latitude > 15 ||
        anchor.latitude < 8 ||
        anchor.longitude < 100 ||
        anchor.longitude > 110) {
      anchor = const LatLng(10.8220, 106.6875);
    }

    List<SearchResultPlace> results = [];

    // 1. Thử truy vấn qua Photon API với tọa độ neo Việt Nam
    try {
      final searchUrl = Uri.parse(
        'https://photon.komoot.io/api/?q=${Uri.encodeComponent(query)}&limit=8&lat=${anchor.latitude}&lon=${anchor.longitude}',
      );
      final res = await http.get(searchUrl).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = json.decode(utf8.decode(res.bodyBytes));
        final features = data['features'] as List;

        for (var f in features) {
          final props = f['properties'] as Map<String, dynamic>;
          final geom = f['geometry']['coordinates'] as List;
          final name = props['name'] ?? query;

          List<String> subParts = [];
          if (props['street'] != null) subParts.add(props['street']);
          if (props['district'] != null) subParts.add(props['district']);
          if (props['city'] != null) subParts.add(props['city']);
          if (props['state'] != null && props['state'] != props['city']) {
            subParts.add(props['state']);
          }
          if (props['country'] != null) subParts.add(props['country']);

          String subtitle = subParts.isNotEmpty
              ? subParts.join(', ')
              : 'Địa điểm trên bản đồ';

          results.add(
            SearchResultPlace(
              title: name,
              subtitle: subtitle,
              location: LatLng(
                (geom[1] as num).toDouble(),
                (geom[0] as num).toDouble(),
              ),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint("Photon error: $e");
    }

    // 2. Dự phòng: Nếu Photon trả về ít hơn 3 kết quả hoặc lỗi, gọi tiếp Nominatim OpenStreetMap
    if (results.length < 3) {
      try {
        final nomUrl = Uri.parse(
          'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(query)}&format=json&limit=6&countrycodes=vn',
        );
        final nomRes = await http
            .get(nomUrl, headers: {'User-Agent': 'TeaNaviMapApp/1.0'})
            .timeout(const Duration(seconds: 4));

        if (nomRes.statusCode == 200) {
          final nomData = json.decode(utf8.decode(nomRes.bodyBytes)) as List;
          for (var item in nomData) {
            String name = item['name'] ?? query;
            String displayName = item['display_name'] ?? '';
            double lat = double.tryParse(item['lat'].toString()) ?? 0;
            double lon = double.tryParse(item['lon'].toString()) ?? 0;

            if (lat != 0 && lon != 0) {
              // Tránh trùng lặp
              bool exists = results.any(
                (r) =>
                    (r.location.latitude - lat).abs() < 0.001 &&
                    (r.location.longitude - lon).abs() < 0.001,
              );
              if (!exists) {
                results.add(
                  SearchResultPlace(
                    title: name.isNotEmpty ? name : query,
                    subtitle: displayName,
                    location: LatLng(lat, lon),
                  ),
                );
              }
            }
          }
        }
      } catch (e) {
        debugPrint("Nominatim error: $e");
      }
    }

    if (!mounted) return;
    setState(() {
      searchSuggestions = results;
      isSearchingSuggestions = false;
    });
  }

  void selectSearchResult(SearchResultPlace place) {
    FocusScope.of(context).unfocus();
    setState(() => searchSuggestions.clear());

    if (activeSearchForOrigin) {
      setState(() {
        originPoint = place.location;
        originName = place.title;
        startController.text = place.title;
      });
      mapController.move(place.location, 16);
      if (destPoint != null) {
        calculateRoute(
          from: originPoint,
          to: destPoint,
          destTitle: destinationName,
        );
      }
    } else {
      setState(() {
        destPoint = place.location;
        destinationName = place.title;
        destController.text = place.title;
      });
      mapController.move(place.location, 16);
      calculateRoute(
        from: originPoint ?? currentPosition,
        to: place.location,
        destTitle: place.title,
      );
    }
  }

  // ==========================================
  // OSRM ROUTE (ĐIỂM ĐI -> ĐIỂM ĐẾN)
  // ==========================================
  Future<void> calculateRoute({
    LatLng? from,
    LatLng? to,
    String? destTitle,
  }) async {
    final start = from ?? originPoint ?? currentPosition;
    final end = to ?? destPoint;

    if (start == null) {
      _showToast('Chưa xác định được điểm xuất phát!');
      return;
    }
    if (end == null) {
      _showToast('Vui lòng chọn hoặc nhập điểm đến!');
      return;
    }

    setState(() {
      isLoadingRoute = true;
      searchSuggestions.clear();
    });

    final osrmUrl = Uri.parse(
      'https://routing.openstreetmap.de/routed-car/route/v1/driving/'
      '${start.longitude},${start.latitude};'
      '${end.longitude},${end.latitude}'
      '?overview=full&steps=true&geometries=geojson',
    );

    try {
      final osrmRes = await http.get(osrmUrl);
      if (osrmRes.statusCode != 200) {
        setState(() => isLoadingRoute = false);
        _showToast('Không thể kết nối máy chủ chỉ đường');
        return;
      }
      final osrmData = json.decode(osrmRes.body);

      if (osrmData['routes'] == null || osrmData['routes'].isEmpty) {
        setState(() => isLoadingRoute = false);
        _showToast('Không tìm thấy tuyến đường giữa 2 vị trí này!');
        return;
      }

      final route = osrmData['routes'][0];
      final geometry = route['geometry']['coordinates'] as List;

      if (!mounted) return;
      setState(() {
        isLoadingRoute = false;
        routePoints = geometry.map((pt) => LatLng(pt[1], pt[0])).toList();
        navSteps = parseOsrmSteps(route['legs'][0]['steps']);
        currentStepIndex = 0;
        isNavigating = true;
        destPoint = end;
        if (destTitle != null) {
          destinationName = destTitle;
          destController.text = destTitle;
        }
        totalRouteDistanceKm = (route['distance'] as num).toDouble() / 1000;
      });

      if (routePoints.isNotEmpty) {
        mapController.move(start, 15);
      }

      syncTimer?.cancel();
      syncTimer = Timer.periodic(const Duration(milliseconds: 800), (t) {
        if (isNavigating && navSteps.isNotEmpty) {
          processNavigationUpdate();
        }
      });

      processNavigationUpdate();
      _showToast(
        'Bắt đầu lộ trình: ${destinationName.isNotEmpty ? destinationName : 'Điểm đến'} (${totalRouteDistanceKm.toStringAsFixed(1)} km)',
      );
    } catch (e) {
      if (mounted) setState(() => isLoadingRoute = false);
      debugPrint("Lỗi OSRM: $e");
    }
  }

  void swapOriginAndDestination() {
    setState(() {
      final tempPt = originPoint;
      originPoint = destPoint;
      destPoint = tempPt;

      final tempName = originName;
      originName = destinationName.isEmpty ? "Vị trí đã chọn" : destinationName;
      destinationName = tempName;

      startController.text = originName;
      destController.text = destinationName;
    });

    if (originPoint != null && destPoint != null) {
      calculateRoute(
        from: originPoint,
        to: destPoint,
        destTitle: destinationName,
      );
    }
  }

  void cancelNavigation() {
    setState(() {
      isNavigating = false;
      routePoints.clear();
      navSteps.clear();
      destinationName = "";
      destController.clear();
      destPoint = null;
    });
    syncTimer?.cancel();
    _showToast('Đã dừng dẫn đường');
  }

  int _osrmToNavDir(String type, String modifier) {
    if (type == 'arrive') return 11;
    if (type == 'roundabout' || type == 'rotary' || type == 'roundabout turn') {
      return 10;
    }
    if (type == 'fork' || type == 'on ramp' || type == 'off ramp') return 9;
    if (modifier == 'uturn') return 7;

    if (type == 'depart' ||
        type == 'continue' ||
        type == 'new name' ||
        type == 'notification' ||
        type == 'use lane') {
      if (modifier == 'left') return 5;
      if (modifier == 'slight left') return 4;
      if (modifier == 'right') return 2;
      if (modifier == 'slight right') return 1;
      return 0;
    }

    if (type == 'end of road' || type == 'merge') {
      if (modifier == 'right' || modifier == 'slight right') return 2;
      if (modifier == 'left' || modifier == 'slight left') return 5;
      return 0;
    }

    if (modifier == 'slight right') return 1;
    if (modifier == 'right') return 2;
    if (modifier == 'sharp right') return 3;
    if (modifier == 'slight left') return 4;
    if (modifier == 'left') return 5;
    if (modifier == 'sharp left') return 6;
    return 0;
  }

  List<NavigationStep> parseOsrmSteps(List stepsJson) {
    List<NavigationStep> steps = [];
    for (var s in stepsJson) {
      var maneuver = s['maneuver'];
      String type = maneuver['type'] ?? '';
      String modifier = maneuver['modifier'] ?? '';
      int exitNum = maneuver['exit'] ?? 1;

      int dirEnum = _osrmToNavDir(type, modifier);
      double dist = (s['distance'] as num).toDouble();
      String name = (s['name'] == null || s['name'].toString().isEmpty)
          ? "Tiếp tục đi thẳng"
          : s['name'];
      var loc = maneuver['location'];

      steps.add(
        NavigationStep(
          direction: dirEnum,
          distance: dist,
          streetName: name,
          instruction: s['maneuver']['type'] ?? '',
          location: LatLng(loc[1], loc[0]),
          exitNumber: exitNum,
        ),
      );
    }
    return steps;
  }

  void processNavigationUpdate() {
    if (navSteps.isEmpty || currentStepIndex >= navSteps.length) return;

    NavigationStep step = navSteps[currentStepIndex];

    // Sử dụng refPosition phù hợp khi chọn điểm đi tùy chọn hay GPS máy
    final LatLng refPosition =
        (originPoint != null && originPoint != currentPosition)
        ? originPoint!
        : (currentPosition ?? step.location);

    double distToManeuver =
        (originPoint != null && originPoint != currentPosition)
        ? step.distance
        : Geolocator.distanceBetween(
            refPosition.latitude,
            refPosition.longitude,
            step.location.latitude,
            step.location.longitude,
          );

    if (distToManeuver < 15 && currentStepIndex < navSteps.length - 1) {
      currentStepIndex++;
      step = navSteps[currentStepIndex];
    }

    sendNavPacketToHUD(
      direction: step.direction,
      distanceMeters: distToManeuver.round(),
      speedKmH: currentSpeed.round(),
      speedLimit: 60,
      exitNum: step.exitNumber,
      streetName: step.streetName,
    );
  }

  IconData _getTurnIcon(int dir) {
    switch (dir) {
      case 1:
        return Icons.turn_slight_right_rounded;
      case 2:
        return Icons.turn_right_rounded;
      case 3:
        return Icons.turn_sharp_right_rounded;
      case 4:
        return Icons.turn_slight_left_rounded;
      case 5:
        return Icons.turn_left_rounded;
      case 6:
        return Icons.turn_sharp_left_rounded;
      case 7:
      case 8:
        return Icons.u_turn_left_rounded;
      case 9:
        return Icons.alt_route_rounded;
      case 10:
        return Icons.roundabout_left_rounded;
      case 11:
        return Icons.place_rounded;
      default:
        return Icons.straight_rounded;
    }
  }

  // ==========================================
  // GIAO DIỆN HIỆN ĐẠI (MINIMAL MODERN IOS STYLE)
  // ==========================================
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;
    final topPadding = MediaQuery.of(context).padding.top;
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    final glassBg = isDark
        ? const Color(0xFF1C1C1E).withValues(alpha: 0.90)
        : Colors.white.withValues(alpha: 0.92);
    final glassBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.06);
    final textColor = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final secondaryTextColor = isDark ? Colors.white60 : Colors.black54;

    return Scaffold(
      body: Stack(
        children: [
          // 1. Fullscreen Map (Edge-to-Edge)
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: currentPosition ?? const LatLng(10.8220, 106.6875),
              initialZoom: 15.5,
              onTap: (tapPosition, point) {
                FocusScope.of(context).unfocus();
                setState(() => searchSuggestions.clear());

                final coordStr =
                    "${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)}";

                if (isSelectingOrigin) {
                  setState(() {
                    originPoint = point;
                    originName = coordStr;
                    startController.text = coordStr;
                  });
                  _showToast('Đã chọn điểm xuất phát trên bản đồ');
                  if (destPoint != null) {
                    calculateRoute(from: originPoint, to: destPoint);
                  }
                } else {
                  setState(() {
                    destPoint = point;
                    destinationName = coordStr;
                    destController.text = coordStr;
                  });
                  calculateRoute(
                    from: originPoint ?? currentPosition,
                    to: point,
                    destTitle: "Điểm ghim trên bản đồ",
                  );
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: isDark
                    ? 'https://{s}.basemaps.cartocdn.com/rastertiles/dark_all/{z}/{x}/{y}@2x.png'
                    : 'https://mt{s}.google.com/vt/lyrs=m&hl=vi&x={x}&y={y}&z={z}',
                subdomains: isDark
                    ? const ['a', 'b', 'c', 'd']
                    : const ['0', '1', '2', '3'],
                userAgentPackageName: 'com.teaverse.teanavi_map',
                fallbackUrl: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              ),
              if (routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: routePoints,
                      strokeWidth: 8.0,
                      color: primaryColor.withValues(alpha: 0.35),
                    ),
                    Polyline(
                      points: routePoints,
                      strokeWidth: 5.0,
                      color: primaryColor,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (currentPosition != null)
                    Marker(
                      point: currentPosition!,
                      width: 50,
                      height: 50,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: primaryColor.withValues(alpha: 0.18),
                            ),
                          ),
                          Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: primaryColor,
                              border: Border.all(color: Colors.white, width: 3),
                              boxShadow: [
                                BoxShadow(
                                  color: primaryColor.withValues(alpha: 0.45),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Transform.rotate(
                              angle: (currentHeading * pi) / 180,
                              child: const Icon(
                                Icons.navigation,
                                size: 12,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (originPoint != null && originPoint != currentPosition)
                    Marker(
                      point: originPoint!,
                      width: 40,
                      height: 40,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF34C759),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: const [
                            BoxShadow(color: Colors.black26, blurRadius: 6),
                          ],
                        ),
                        child: const Icon(
                          Icons.trip_origin_rounded,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  if (destPoint != null)
                    Marker(
                      point: destPoint!,
                      width: 44,
                      height: 44,
                      child: const Icon(
                        Icons.location_on_rounded,
                        color: Color(0xFFFF3B30),
                        size: 40,
                      ),
                    ),
                ],
              ),
            ],
          ),

          // 2. Top Header & Thanh tìm kiếm (Khi KHÔNG trong chế độ dẫn đường)
          if (!isNavigating)
            Positioned(
              top: topPadding + 10,
              left: 16,
              right: 16,
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header Capsule
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: glassBg,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: glassBorder),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.06),
                                blurRadius: 12,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: primaryColor,
                                ),
                                child: const Icon(
                                  Icons.navigation_rounded,
                                  size: 14,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'TeaNavi',
                                style: TextStyle(
                                  color: textColor,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                  letterSpacing: -0.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                        child: InkWell(
                          onTap: isConnected ? disconnectBle : startScanBle,
                          borderRadius: BorderRadius.circular(24),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: isConnected
                                  ? (isDark
                                        ? const Color(0xFF30D158).withValues(alpha: 0.2)
                                        : const Color(0xFF34C759).withValues(alpha: 0.15))
                                  : glassBg,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: isConnected
                                    ? const Color(0xFF34C759).withValues(alpha: 0.5)
                                    : glassBorder,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isScanning)
                                  const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                else
                                  Icon(
                                    isConnected
                                        ? Icons.bluetooth_connected_rounded
                                        : Icons.bluetooth_rounded,
                                    size: 16,
                                    color: isConnected
                                        ? const Color(0xFF34C759)
                                        : secondaryTextColor,
                                  ),
                                const SizedBox(width: 6),
                                Text(
                                  isConnected
                                      ? 'HUD Đã kết nối'
                                      : (isScanning ? 'Đang quét...' : 'Kết nối HUD'),
                                  style: TextStyle(
                                    color: isConnected
                                        ? const Color(0xFF34C759)
                                        : textColor,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Card Điểm đi & Điểm đến (Modern Glass Planner)
                ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: glassBg,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: glassBorder),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
                            blurRadius: 20,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: _buildOriginDestinationPanel(
                        textColor: textColor,
                        secondaryTextColor: secondaryTextColor,
                        primaryColor: primaryColor,
                        isDark: isDark,
                      ),
                    ),
                  ),
                ),

                // 3. DANH SÁCH GỢI Ý AUTOCOMPLETE (SEARCH RESULTS LIST)
                if (searchSuggestions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                        child: Container(
                          constraints: const BoxConstraints(maxHeight: 280),
                          decoration: BoxDecoration(
                            color: glassBg,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: glassBorder),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.12),
                                blurRadius: 20,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: ListView.separated(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              shrinkWrap: true,
                              physics: const BouncingScrollPhysics(),
                              itemCount: searchSuggestions.length,
                              separatorBuilder: (_, _) => Divider(
                                height: 1,
                                color: isDark ? Colors.white12 : Colors.black12,
                              ),
                              itemBuilder: (context, index) {
                                final item = searchSuggestions[index];
                                return ListTile(
                                  leading: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: primaryColor.withValues(
                                        alpha: 0.12,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.location_on_rounded,
                                      size: 20,
                                      color: primaryColor,
                                    ),
                                  ),
                                  title: Text(
                                    item.title,
                                    style: TextStyle(
                                      color: textColor,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    item.subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: secondaryTextColor,
                                      fontSize: 12,
                                    ),
                                  ),
                                  onTap: () => selectSearchResult(item),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                const SizedBox(height: 10),

                // Quick Short-cuts
                if (searchSuggestions.isEmpty)
                  SizedBox(
                    height: 36,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      itemCount: quickPlaces.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final item = quickPlaces[index];
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                            child: InkWell(
                              onTap: () {
                                destController.text = item.query;
                                onSearchTextChanged(
                                  item.query,
                                  forOrigin: false,
                                );
                              },
                              borderRadius: BorderRadius.circular(18),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: glassBg,
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(color: glassBorder),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.04,
                                      ),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      item.icon,
                                      size: 16,
                                      color: primaryColor,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      item.title,
                                      style: TextStyle(
                                        color: textColor,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),

          // 2B. BANNER CHỈ ĐƯỜNG TRÊN ĐỈNH KHI ĐANG DẪN ĐƯỜNG (APPLE / GOOGLE MAPS STYLE)
          if (isNavigating && navSteps.isNotEmpty)
            Positioned(
              top: topPadding + 10,
              left: 16,
              right: 16,
              child: _buildTopNavigationBanner(
                textColor: textColor,
                secondaryTextColor: secondaryTextColor,
                primaryColor: primaryColor,
                glassBg: glassBg,
                glassBorder: glassBorder,
                isDark: isDark,
              ),
            ),

          // 4. Right Floating Map Controls
          Positioned(
            right: 16,
            bottom: isNavigating ? (isRouteStepsExpanded ? 340 : 200) : 130,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildMapControlBtn(
                  icon: Icons.add_rounded,
                  isDark: isDark,
                  glassBg: glassBg,
                  glassBorder: glassBorder,
                  textColor: textColor,
                  onTap: () {
                    mapController.move(
                      mapController.camera.center,
                      mapController.camera.zoom + 1,
                    );
                  },
                ),
                const SizedBox(height: 8),
                _buildMapControlBtn(
                  icon: Icons.remove_rounded,
                  isDark: isDark,
                  glassBg: glassBg,
                  glassBorder: glassBorder,
                  textColor: textColor,
                  onTap: () {
                    mapController.move(
                      mapController.camera.center,
                      mapController.camera.zoom - 1,
                    );
                  },
                ),
                const SizedBox(height: 8),
                _buildMapControlBtn(
                  icon: Icons.my_location_rounded,
                  isDark: isDark,
                  glassBg: glassBg,
                  glassBorder: glassBorder,
                  textColor: primaryColor,
                  onTap: () {
                    if (currentPosition != null) {
                      mapController.move(currentPosition!, 16);
                    }
                  },
                ),
              ],
            ),
          ),

          // 5. Compact Floating HUD & Navigation Bottom Card
          Positioned(
            left: 16,
            right: 16,
            bottom: max(bottomPadding, 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    color: glassBg,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: glassBorder),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: isNavigating && navSteps.isNotEmpty
                      ? _buildNavigatingDashboard(
                          textColor: textColor,
                          secondaryTextColor: secondaryTextColor,
                          primaryColor: primaryColor,
                          isDark: isDark,
                        )
                      : _buildIdleDashboard(
                          textColor: textColor,
                          secondaryTextColor: secondaryTextColor,
                          primaryColor: primaryColor,
                          isDark: isDark,
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOriginDestinationPanel({
    required Color textColor,
    required Color secondaryTextColor,
    required Color primaryColor,
    required bool isDark,
  }) {
    final inputBg = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.04);
    final inputBorder = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.06);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Left route connector (Green circle -> line -> Red pin)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () {
                    setState(() => isSelectingOrigin = true);
                    _showToast('Chế độ: Chạm bản đồ để chọn Điểm xuất phát');
                  },
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF34C759).withValues(alpha: 0.15),
                      border: Border.all(
                        color: const Color(0xFF34C759),
                        width: 2.2,
                      ),
                    ),
                    child: Center(
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: Color(0xFF34C759),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ),
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  width: 2,
                  height: 28,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.black12,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    setState(() => isSelectingOrigin = false);
                    _showToast('Chế độ: Chạm bản đồ để chọn Điểm đến');
                  },
                  child: Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.location_on_rounded,
                      color: Color(0xFFFF3B30),
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),

            // Middle input fields (Origin + Destination)
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 1. Origin Input Field
                  Container(
                    height: 38,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: inputBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: inputBorder),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: startController,
                            style: TextStyle(
                              color: textColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Điểm đi (Mặc định: Vị trí của bạn)',
                              hintStyle: TextStyle(
                                color: secondaryTextColor,
                                fontSize: 12,
                                fontWeight: FontWeight.normal,
                              ),
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                            onChanged: (text) =>
                                onSearchTextChanged(text, forOrigin: true),
                            onSubmitted: (text) =>
                                fetchLocationSuggestions(text),
                          ),
                        ),
                        if (startController.text.isNotEmpty &&
                            startController.text != "Vị trí của bạn")
                          GestureDetector(
                            onTap: () {
                              startController.clear();
                              setState(() {
                                originPoint = null;
                                originName = "";
                                searchSuggestions.clear();
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(4.0),
                              child: Icon(
                                Icons.cancel_rounded,
                                size: 16,
                                color: secondaryTextColor,
                              ),
                            ),
                          ),
                        InkWell(
                          onTap: () {
                            if (currentPosition != null) {
                              setState(() {
                                originPoint = currentPosition;
                                originName = "Vị trí của bạn";
                                startController.text = originName;
                                searchSuggestions.clear();
                              });
                              _showToast('Đã chọn điểm đi là Vị trí hiện tại');
                              if (destPoint != null) {
                                calculateRoute(from: originPoint, to: destPoint);
                              }
                            }
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.all(4.0),
                            child: Icon(
                              Icons.my_location_rounded,
                              size: 16,
                              color: (originPoint == currentPosition ||
                                      originPoint == null)
                                  ? primaryColor
                                  : secondaryTextColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 8),

                  // 2. Destination Input Field
                  Container(
                    height: 38,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: inputBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: inputBorder),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: destController,
                            style: TextStyle(
                              color: textColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Nhập điểm đến...',
                              hintStyle: TextStyle(
                                color: secondaryTextColor,
                                fontSize: 12,
                                fontWeight: FontWeight.normal,
                              ),
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                            onChanged: (text) =>
                                onSearchTextChanged(text, forOrigin: false),
                            onSubmitted: (text) =>
                                fetchLocationSuggestions(text),
                          ),
                        ),
                        if (isSearchingSuggestions)
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 6),
                            child: SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        else if (destController.text.isNotEmpty)
                          GestureDetector(
                            onTap: () {
                              destController.clear();
                              setState(() => searchSuggestions.clear());
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(4.0),
                              child: Icon(
                                Icons.cancel_rounded,
                                size: 16,
                                color: secondaryTextColor,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),

            // Right side buttons: Swap & Search/Go button
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Swap button
                InkWell(
                  onTap: swapOriginAndDestination,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: inputBg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: inputBorder),
                    ),
                    child: Icon(
                      Icons.swap_vert_rounded,
                      size: 20,
                      color: primaryColor,
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                // Find route action button
                InkWell(
                  onTap: () {
                    if (searchSuggestions.isNotEmpty) {
                      selectSearchResult(searchSuggestions.first);
                    } else if (destPoint != null) {
                      calculateRoute(
                        from: originPoint ?? currentPosition,
                        to: destPoint,
                      );
                    } else {
                      fetchLocationSuggestions(destController.text);
                    }
                  },
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: primaryColor,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: primaryColor.withValues(alpha: 0.35),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: isLoadingRoute
                        ? const Center(
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                          )
                        : const Icon(
                            Icons.directions_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMapControlBtn({
    required IconData icon,
    required bool isDark,
    required Color glassBg,
    required Color glassBorder,
    required Color textColor,
    required VoidCallback onTap,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: glassBg,
              shape: BoxShape.circle,
              border: Border.all(color: glassBorder),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Icon(icon, size: 20, color: textColor),
          ),
        ),
      ),
    );
  }

  Widget _buildIdleDashboard({
    required Color textColor,
    required Color secondaryTextColor,
    required Color primaryColor,
    required bool isDark,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${currentSpeed.round()}',
                style: TextStyle(
                  color: textColor,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'KM/H',
                style: TextStyle(
                  color: secondaryTextColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Sẵn sàng dẫn đường',
                style: TextStyle(
                  color: textColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                isConnected
                    ? 'Đang phát sóng BLE sang HUD ESP32'
                    : 'Chạm điểm trên map hoặc nhập điểm đi & đến',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isConnected
                      ? const Color(0xFF34C759)
                      : secondaryTextColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Banner chỉ đường nổi trên đỉnh (Apple Maps / Google Maps Dark Cyber HUD Style)
  Widget _buildTopNavigationBanner({
    required Color textColor,
    required Color secondaryTextColor,
    required Color primaryColor,
    required Color glassBg,
    required Color glassBorder,
    required bool isDark,
  }) {
    final currentStep = navSteps[currentStepIndex];
    final LatLng refPosition =
        (originPoint != null && originPoint != currentPosition)
            ? originPoint!
            : (currentPosition ?? currentStep.location);

    double distToManeuver =
        (originPoint != null && originPoint != currentPosition)
            ? currentStep.distance
            : Geolocator.distanceBetween(
                refPosition.latitude,
                refPosition.longitude,
                currentStep.location.latitude,
                currentStep.location.longitude,
              );

    // Bước rẽ kế tiếp (Next step preview)
    NavigationStep? nextStep;
    if (currentStepIndex + 1 < navSteps.length) {
      nextStep = navSteps[currentStepIndex + 1];
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xFF131622).withValues(alpha: 0.94)
                : const Color(0xFF1C1C1E).withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: isDark
                  ? primaryColor.withValues(alpha: 0.35)
                  : Colors.white.withValues(alpha: 0.15),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Icon ngã rẽ lớn nổi bật màu xanh Neon HUD
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          primaryColor,
                          primaryColor.withValues(alpha: 0.75),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: primaryColor.withValues(alpha: 0.4),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Icon(
                      _getTurnIcon(currentStep.direction),
                      color: Colors.white,
                      size: 34,
                    ),
                  ),
                  const SizedBox(width: 14),
                  // Thông tin khoảng cách và tên đường cần rẽ
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          distToManeuver < 1000
                              ? 'Còn ${distToManeuver.round()} m'
                              : 'Còn ${(distToManeuver / 1000).toStringAsFixed(1)} km',
                          style: TextStyle(
                            color: primaryColor,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          currentStep.streetName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Nút kết nối HUD nhỏ gọn
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isConnected
                          ? const Color(0xFF34C759).withValues(alpha: 0.2)
                          : Colors.white.withValues(alpha: 0.08),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isConnected
                          ? Icons.bluetooth_connected_rounded
                          : Icons.bluetooth_rounded,
                      size: 18,
                      color: isConnected ? const Color(0xFF34C759) : Colors.white60,
                    ),
                  ),
                ],
              ),
              // Xem trước ngã rẽ tiếp theo (Sau đó rẽ vào đâu)
              if (nextStep != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Text(
                        'Sau đó:',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        _getTurnIcon(nextStep.direction),
                        size: 14,
                        color: Colors.white70,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          nextStep.streetName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavigatingDashboard({
    required Color textColor,
    required Color secondaryTextColor,
    required Color primaryColor,
    required bool isDark,
  }) {
    // Ước tính thời gian đến (Dựa trên vận tốc trung bình 35 km/h trong nội thành)
    final int estimatedMinutes = max(1, ((totalRouteDistanceKm / 35) * 60).round());
    final now = DateTime.now().add(Duration(minutes: estimatedMinutes));
    final String etaTimeStr =
        "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Thanh vuốt kéo mở rộng / thu gọn danh sách lộ trình
        GestureDetector(
          onTap: () {
            setState(() {
              isRouteStepsExpanded = !isRouteStepsExpanded;
            });
          },
          child: Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.black12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),

        // Hàng thông tin tổng quan lộ trình: Thời gian còn lại | Tổng quãng đường | Giờ đến dự kiến
        Row(
          children: [
            // Cụm thông số ETA to rõ
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '$estimatedMinutes',
                        style: TextStyle(
                          color: const Color(0xFF34C759), // Màu xanh thành công iOS
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'phút',
                        style: TextStyle(
                          color: const Color(0xFF34C759),
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '${totalRouteDistanceKm.toStringAsFixed(1)} km',
                        style: TextStyle(
                          color: textColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '• Đến lúc $etaTimeStr',
                        style: TextStyle(
                          color: secondaryTextColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    destinationName.isNotEmpty ? destinationName : 'Đích đến',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: secondaryTextColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),

            // Nút Dừng lộ trình dạng Pill tròn thanh lịch
            InkWell(
              onTap: cancelNavigation,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF3B30).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: Color(0xFFFF3B30),
                    ),
                    SizedBox(width: 4),
                    Text(
                      'Dừng',
                      style: TextStyle(
                        color: Color(0xFFFF3B30),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),

        // Bảng danh sách toàn bộ các ngã rẽ (Hiện ra khi bấm hoặc vuốt mở rộng)
        if (isRouteStepsExpanded) ...[
          const SizedBox(height: 12),
          Container(
            height: 1,
            color: isDark ? Colors.white12 : Colors.black12,
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView.separated(
              physics: const BouncingScrollPhysics(),
              shrinkWrap: true,
              itemCount: navSteps.length,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                color: isDark ? Colors.white12 : Colors.black12,
              ),
              itemBuilder: (context, index) {
                final s = navSteps[index];
                final bool isCurrent = index == currentStepIndex;
                return Container(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? primaryColor.withValues(alpha: 0.08)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: isCurrent
                              ? primaryColor
                              : (isDark ? Colors.white10 : Colors.black12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _getTurnIcon(s.direction),
                          size: 16,
                          color: isCurrent
                              ? Colors.white
                              : (isDark ? Colors.white70 : Colors.black87),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          s.streetName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isCurrent ? primaryColor : textColor,
                            fontSize: 13,
                            fontWeight: isCurrent
                                ? FontWeight.w700
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                      Text(
                        s.distance < 1000
                            ? '${s.distance.round()} m'
                            : '${(s.distance / 1000).toStringAsFixed(1)} km',
                        style: TextStyle(
                          color: secondaryTextColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}
