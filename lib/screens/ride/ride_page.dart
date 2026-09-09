import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/reservation_provider.dart';
import '../../providers/ride_history_provider.dart';
import '../../models/reservation.dart';
import '../../models/ride_info.dart';
import '../../services/reservation_service.dart';
// 新增导入
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';
import '../../providers/auth_provider.dart';
import 'package:intl/intl.dart';
import '../../providers/brightness_provider.dart';
import '../settings/ride_settings_page.dart'; // 导入 BrightnessControlMode 枚举

// 导入新的组件
import 'ride_card.dart';

class RidePage extends StatefulWidget {
  const RidePage({super.key});

  @override
  RidePageState createState() => RidePageState();
}

class RidePageState extends State<RidePage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _isToggleLoading = false;

  bool _isGoingToYanyuan = true;

  List<Map<String, dynamic>> _nearbyBuses = [];
  int _selectedBusIndex = -1;

  // 添加预约相关变量

  // 添加 PageController 属性
  late PageController _pageController;

  // 添加一个加载状态变量
  bool _isLoading = true;

  // 添加一个新的列来存储每个卡片的状态
  List<Map<String, dynamic>> _cardStates = [];

  // 添加新的属性
  bool _autoReservationEnabled = false;
  bool _hasAttemptedAutoReservation = false;

  // 添加新的状态变量
  BrightnessControlMode? _brightnessMode;

  // 添加 BrightnessProvider 引用
  late BrightnessProvider _brightnessProvider;

  // 添加新的状态变量来跟踪当前加载步骤
  String _loadingStep = '正在初始化...';

  // 添加新的状态变量
  bool _showRetryButton = false;
  bool _isRetrying = false;

  DateTime? _lastRetryTime;

  // 只有最新一轮初始化可以回写页面状态。
  int _initializationGeneration = 0;

  bool _hasStartedRideHistoryRefresh = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _brightnessProvider =
        Provider.of<BrightnessProvider>(context, listen: false);
  }

  @override
  void initState() {
    super.initState();
    _initialize();
    _loadAutoReservationSetting();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      refreshSettings();
    });

    _pageController = PageController(
      initialPage: 0,
      viewportFraction: 0.9,
    );
    _startSlowLoadingTimer();
  }

  void _startSlowLoadingTimer() {
    Future.delayed(Duration(seconds: 2), () {
      if (mounted && _isLoading) {
        setState(() {
          _showRetryButton = true;
          _loadingStep = '加载缓慢，可能是校园网连接较弱';
        });
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    if (_brightnessMode == BrightnessControlMode.auto) {
      _brightnessProvider.disableAutoMode();
    } else if (_brightnessMode == BrightnessControlMode.manual) {
      _brightnessProvider.cleanup();
    }
    super.dispose();
  }

  // 修改 _initialize 方法以并行获取所有班车的数据
  Future<void> _initialize() async {
    final generation = ++_initializationGeneration;

    if (mounted) {
      setState(() {
        _isToggleLoading = false;
        _loadingStep = '正在获取班车列表...';
      });
    }

    try {
      await _loadNearbyBuses(generation);

      if (!_isCurrentInitialization(generation)) return;

      if (_nearbyBuses.isEmpty) {
        setState(() {
          _isLoading = false;
          _loadingStep = '当前无可用班车';
          _cardStates = [];
        });
        return;
      }

      setState(() {
        _selectedBusIndex = 0;
        _loadingStep = '正在初始化班车状态...';
        _cardStates = List.generate(
          _nearbyBuses.length,
          (index) => {
            'qrCode': null,
            'departureTime': '',
            'routeName': '',
            'codeType': '',
            'errorMessage': '',
          },
        );
      });

      if (!_isCurrentInitialization(generation)) return;
      setState(() {
        _loadingStep = '正在获取班车信息...';
      });

      await Future.wait([
        for (int i = 0; i < _nearbyBuses.length; i++)
          _fetchBusData(i, generation),
      ]);

      if (!_isCurrentInitialization(generation)) return;
      if (_autoReservationEnabled && !_hasAttemptedAutoReservation) {
        setState(() {
          _loadingStep = '正在尝试自动预约...';
        });
        await _tryAutoReservation(generation);
      }

      if (_isCurrentInitialization(generation)) {
        setState(() {
          _isLoading = false;
          _loadingStep = '加载完成';
        });
        _refreshRideHistoryInBackground();
      }
    } catch (e) {
      if (_isCurrentInitialization(generation)) {
        setState(() {
          _isLoading = false;
          _loadingStep = '加载失败: ${e.toString()}';
        });
      }
    }
  }

  bool _isCurrentInitialization(int generation) {
    return mounted && generation == _initializationGeneration;
  }

  // 新增方法，用于并行获取每个班车的数据而不改变选中的班车索引
  Future<void> _fetchBusData(int index, int generation) async {
    if (!_isCurrentInitialization(generation) ||
        index < 0 ||
        index >= _nearbyBuses.length) {
      return;
    }

    final bus = Map<String, dynamic>.from(_nearbyBuses[index]);
    final reservationProvider =
        Provider.of<ReservationProvider>(context, listen: false);
    final reservationService =
        ReservationService(Provider.of<AuthProvider>(context, listen: false));

    try {
      await reservationProvider.loadCurrentReservations();
      if (!_isCurrentInitialization(generation)) return;

      Reservation? matchingReservation;

      try {
        matchingReservation =
            reservationProvider.currentReservations.firstWhere(
          (reservation) =>
              reservation.resourceName == bus['route_name'] &&
              reservation.appointmentTime ==
                  '${bus['abscissa']} ${bus['yaxis']}',
        );
      } catch (e) {
        matchingReservation = null;
      }

      if (matchingReservation != null) {
        await _fetchQRCodeForInitialization(
          reservationService,
          matchingReservation,
          index,
          generation,
        );
      } else {
        final departureTimeStr = bus['yaxis'];
        final nowStr = DateFormat('HH:mm').format(DateTime.now());
        final isPastDeparture = departureTimeStr.compareTo(nowStr) <= 0;

        if (isPastDeparture) {
          final tempCode = await _fetchTempCode(reservationService, bus);
          if (!_isCurrentInitialization(generation) ||
              index >= _cardStates.length) {
            return;
          }
          if (tempCode != null) {
            setState(() {
              _cardStates[index] = {
                'qrCode': tempCode['code'],
                'departureTime': tempCode['departureTime']!,
                'routeName': bus['route_name'],
                'codeType': '临时码',
                'errorMessage': '',
              };
            });
          } else {
            setState(() {
              _cardStates[index]['errorMessage'] = '无法获取临时码';
            });
          }
        } else if (_isCurrentInitialization(generation) &&
            index < _cardStates.length) {
          setState(() {
            _cardStates[index] = {
              'qrCode': null,
              'departureTime': bus['yaxis'],
              'routeName': bus['route_name'],
              'codeType': '待预约',
              'errorMessage': '',
            };
          });
        }
      }
    } catch (e) {
      if (_isCurrentInitialization(generation) && index < _cardStates.length) {
        setState(() {
          _cardStates[index]['errorMessage'] = '加载数据时出错: $e';
        });
      }
    }
  }

  Future<void> _loadNearbyBuses(int generation) async {
    if (_isCurrentInitialization(generation)) {
      setState(() {
        _loadingStep = '正在检查缓存数据...';
      });
    }

    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final todayString = now.toIso8601String().split('T')[0];

    final cachedBusDataString = prefs.getString('cachedBusData');
    final cachedDate = prefs.getString('cachedDate');

    if (cachedBusDataString != null && cachedDate == todayString) {
      if (_isCurrentInitialization(generation)) {
        setState(() {
          _loadingStep = '正在加载缓存数据...';
        });
      }
      final cachedBusData = json.decode(cachedBusDataString);
      _processBusData(cachedBusData, generation);
    } else {
      if (!mounted || generation != _initializationGeneration) return;

      setState(() {
        _loadingStep = '正在从服务器获取班车数据...';
      });

      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final reservationService = ReservationService(authProvider);

      try {
        final allBuses = await reservationService.getAllBuses([todayString]);
        await prefs.setString('cachedBusData', json.encode(allBuses));
        await prefs.setString('cachedDate', todayString);

        if (!_isCurrentInitialization(generation)) return;

        setState(() {
          _loadingStep = '正在处理班车数据...';
        });
        _processBusData(allBuses, generation);
      } catch (e) {
        if (_isCurrentInitialization(generation)) {
          setState(() {
            _loadingStep = '加载班车数据失败: $e';
          });
        }
        debugPrint('加载附近班车失败: $e');
      }
    }

    if (_isCurrentInitialization(generation)) {
      setState(() {
        _loadingStep = '正在应用乘车偏好...';
      });
      await _applyCachedRideHistory(generation);
    }
  }

  void _processBusData(List<dynamic> busData, int generation) {
    final now = DateTime.now();
    final nearbyBuses = busData
        .where((bus) {
          final busTime = DateTime.parse('${bus['abscissa']} ${bus['yaxis']}');
          final diff = busTime.difference(now).inMinutes;

          final routeName = bus['route_name'].toString().toLowerCase();
          final containsXin = routeName.contains('新');
          final containsYan = routeName.contains('燕');

          return diff >= -30 && diff <= 30 && containsXin && containsYan;
        })
        .toList()
        .cast<Map<String, dynamic>>();

    if (_isCurrentInitialization(generation)) {
      setState(() {
        _nearbyBuses = nearbyBuses;
      });
    }
  }

  Future<void> _applyCachedRideHistory(int generation) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedHistoryJson = prefs.getString('cachedRideHistory');
      if (cachedHistoryJson == null || !_isCurrentInitialization(generation)) {
        return;
      }

      final cachedHistory = CachedRideHistory.fromJson(
        json.decode(cachedHistoryJson) as Map<String, dynamic>,
      );
      _sortNearbyBusesByRideHistory(cachedHistory.rides, generation);
    } catch (e) {
      debugPrint('读取缓存乘车历史失败: $e');
    }
  }

  void _sortNearbyBusesByRideHistory(
      List<RideInfo> rideHistory, int generation) {
    if (!_isCurrentInitialization(generation)) return;

    final Map<String, int> busUsageCount = {};
    for (var bus in _nearbyBuses) {
      final busKey = '${bus['route_name']}_${bus['yaxis']}';
      busUsageCount[busKey] = 0;
    }

    for (var ride in rideHistory) {
      final rideDateTime = DateTime.parse(ride.appointmentTime);
      final rideTime = DateFormat('HH:mm').format(rideDateTime);
      final rideKey = '${ride.resourceName}_$rideTime';
      if (busUsageCount.containsKey(rideKey)) {
        busUsageCount[rideKey] = busUsageCount[rideKey]! + 1;
      }
    }

    final sortedBuses = List<Map<String, dynamic>>.from(_nearbyBuses);
    sortedBuses.sort((a, b) {
      final keyA = '${a['route_name']}_${a['yaxis']}';
      final keyB = '${b['route_name']}_${b['yaxis']}';
      return busUsageCount[keyB]!.compareTo(busUsageCount[keyA]!);
    });

    if (_isCurrentInitialization(generation)) {
      setState(() {
        _nearbyBuses = sortedBuses;
      });
    }
  }

  void _refreshRideHistoryInBackground() {
    if (_hasStartedRideHistoryRefresh || !mounted) return;
    _hasStartedRideHistoryRefresh = true;

    final rideHistoryProvider =
        Provider.of<RideHistoryProvider>(context, listen: false);
    unawaited(rideHistoryProvider.loadRideHistory());
  }

  Future<void> _selectBus(int index) async {
    if (!mounted) return;
    if (index < 0 ||
        index >= _nearbyBuses.length ||
        index >= _cardStates.length) {
      return;
    }

    setState(() {
      _selectedBusIndex = index;
    });

    // 确保 _cardStates 有足够的元素
    if (_cardStates.length <= index) {
      setState(() {
        _cardStates = List.generate(
          _nearbyBuses.length,
          (i) => {
            'qrCode': null,
            'departureTime': '',
            'routeName': '',
            'codeType': '',
            'errorMessage': '',
          },
        );
      });
    }

    // 修改下组件：基于 'codeType' 而不是 'errorMessage'
    if (_cardStates[index]['codeType'] == '乘车码') {
      return; // 如果已经是乘车码，不需要重新获取数据
    }

    final bus = _nearbyBuses[index];
    final reservationProvider =
        Provider.of<ReservationProvider>(context, listen: false);
    final reservationService =
        ReservationService(Provider.of<AuthProvider>(context, listen: false));

    try {
      await reservationProvider.loadCurrentReservations();
      Reservation? matchingReservation;

      try {
        matchingReservation =
            reservationProvider.currentReservations.firstWhere(
          (reservation) =>
              reservation.resourceName == bus['route_name'] &&
              reservation.appointmentTime ==
                  '${bus['abscissa']} ${bus['yaxis']}',
        );
      } catch (e) {
        matchingReservation = null; // 如果没有找到匹配的预约，设置为 null
      }

      if (matchingReservation != null) {
        await _fetchQRCode(reservationProvider, matchingReservation, index);
      } else {
        // 仅比较 HH:mm
        final departureTimeStr = bus['yaxis']; // "HH:mm"
        final nowStr = DateFormat('HH:mm').format(DateTime.now());
        final isPastDeparture = departureTimeStr.compareTo(nowStr) <= 0;

        if (isPastDeparture) {
          final tempCode = await _fetchTempCode(reservationService, bus);
          if (tempCode != null) {
            if (mounted) {
              setState(() {
                _cardStates[index] = {
                  'qrCode': tempCode['code'],
                  'departureTime': tempCode['departureTime']!,
                  'routeName': bus['route_name'],
                  'codeType': '临时码',
                  'errorMessage': '',
                };
              });
            }
          } else {
            if (mounted) {
              setState(() {
                _cardStates[index]['errorMessage'] = '无法获取临时码';
              });
            }
          }
        } else {
          if (mounted) {
            setState(() {
              _cardStates[index] = {
                'qrCode': null,
                'departureTime': bus['yaxis'],
                'routeName': bus['route_name'],
                'codeType': '待预约',
                'errorMessage': '',
              };
            });
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _cardStates[index]['errorMessage'] = '加载数据时出错: $e';
        });
      }
    }
  }

  Future<void> _fetchQRCodeForInitialization(ReservationService service,
      Reservation reservation, int index, int generation) async {
    try {
      final qrCode = await service.getReservationQRCode(
        reservation.id.toString(),
        reservation.hallAppointmentDataId.toString(),
      );
      final actualDepartureTime = await _getActualDepartureTime(reservation);

      if (_isCurrentInitialization(generation) && index < _cardStates.length) {
        setState(() {
          _cardStates[index] = {
            'qrCode': qrCode,
            'departureTime': actualDepartureTime,
            'routeName': reservation.resourceName,
            'codeType': '乘车码',
            'appointmentId': reservation.id.toString(),
            'hallAppointmentDataId':
                reservation.hallAppointmentDataId.toString(),
            'errorMessage': '',
          };
        });
      }
    } catch (e) {
      if (_isCurrentInitialization(generation) && index < _cardStates.length) {
        setState(() {
          _cardStates[index]['errorMessage'] = '获取二维码时出错: $e';
        });
      }
    }
  }

  Future<void> _fetchQRCode(
      ReservationProvider provider, Reservation reservation, int index) async {
    try {
      await provider.fetchQRCode(
        reservation.id.toString(),
        reservation.hallAppointmentDataId.toString(),
      );

      final actualDepartureTime = await _getActualDepartureTime(reservation);

      if (mounted) {
        setState(() {
          _cardStates[index] = {
            'qrCode': provider.qrCode,
            'departureTime': actualDepartureTime,
            'routeName': reservation.resourceName,
            'codeType': '乘车码',
            'appointmentId': reservation.id.toString(),
            'hallAppointmentDataId':
                reservation.hallAppointmentDataId.toString(),
            'errorMessage': '',
          };
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _cardStates[index]['errorMessage'] = '获取二维码时出错: $e';
        });
      }
    }
  }

  Future<String> _getActualDepartureTime(Reservation reservation) async {
    final prefs = await SharedPreferences.getInstance();
    final cachedBusDataString = prefs.getString('cachedBusData');
    if (cachedBusDataString != null) {
      final buses = jsonDecode(cachedBusDataString);
      final matchingBus = buses.firstWhere(
        (bus) =>
            bus['route_name'] == reservation.resourceName &&
            '${bus['abscissa']} ${bus['yaxis']}' == reservation.appointmentTime,
        orElse: () => null,
      );
      if (matchingBus != null) {
        return matchingBus['yaxis'];
      }
    }
    return reservation.appointmentTime.split(' ')[1];
  }

  Future<Map<String, String>?> _fetchTempCode(
      ReservationService service, Map<String, dynamic> bus) async {
    final resourceId = bus['bus_id'].toString();
    final startTime = '${bus['abscissa']} ${bus['yaxis']}';
    final code = await service.getTempQRCode(resourceId, startTime);
    return {
      'code': code,
      'departureTime': bus['yaxis'],
      'routeName': bus['route_name'],
    };
  }

  Future<void> _cancelReservation(int index) async {
    final cardState = _cardStates[index];
    if (cardState['appointmentId'] == null ||
        cardState['hallAppointmentDataId'] == null) {
      setState(() {
        cardState['errorMessage'] = '无有效的预约信息';
      });
      return;
    }

    setState(() {
      _isToggleLoading = true;
      cardState['errorMessage'] = '';
    });

    final reservationService =
        ReservationService(Provider.of<AuthProvider>(context, listen: false));

    try {
      await reservationService.cancelReservation(
        cardState['appointmentId'],
        cardState['hallAppointmentDataId'],
      );

      // 仅比较 HH:mm
      final bus = _nearbyBuses[index];
      final departureTimeStr = bus['yaxis']; // "HH:mm"
      final nowStr = DateFormat('HH:mm').format(DateTime.now());
      final isPastDeparture = departureTimeStr.compareTo(nowStr) <= 0;

      if (isPastDeparture) {
        final tempCode = await _fetchTempCode(reservationService, bus);
        if (tempCode != null) {
          if (mounted) {
            setState(() {
              _cardStates[index] = {
                'qrCode': tempCode['code'],
                'departureTime': tempCode['departureTime']!,
                'routeName': bus['route_name'],
                'codeType': '临时码',
                'errorMessage': '',
              };
            });
          }
        } else {
          if (mounted) {
            setState(() {
              cardState['errorMessage'] = '无法获取临时码';
            });
          }
        }
      } else {
        if (mounted) {
          setState(() {
            _cardStates[index] = {
              'qrCode': null,
              'departureTime': bus['yaxis'],
              'routeName': bus['route_name'],
              'codeType': '待预约',
              'errorMessage': '',
            };
          });
        }
      }
    } catch (e) {
      setState(() {
        cardState['errorMessage'] = '取消预约失败: $e';
      });
    } finally {
      setState(() {
        _isToggleLoading = false;
      });
    }
  }

  // 添加新的方法来加载自动预约设置
  Future<void> _loadAutoReservationSetting() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoReservationEnabled =
          prefs.getBool('autoReservationEnabled') ?? false;
    });
  }

  // 添加新的方法来尝试自动预约
  Future<void> _tryAutoReservation(int generation) async {
    if (!_isCurrentInitialization(generation) ||
        _nearbyBuses.isEmpty ||
        _cardStates.isEmpty ||
        _hasAttemptedAutoReservation) {
      return;
    }

    _hasAttemptedAutoReservation = true;

    // 确保索引有效
    if (_cardStates.isEmpty) return;

    // 检查第一个卡片是否可以预约
    final firstCardState = _cardStates[0];
    if (_isCurrentInitialization(generation) &&
        firstCardState['codeType'] == '待预约') {
      try {
        await _makeReservation(0, generation: generation);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('自动预约失败: ${e.toString()}'),
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
    }
  }

  Future<void> _loadBrightnessMode() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _brightnessMode = BrightnessControlMode.fromStoredIndex(
          prefs.getInt('brightnessMode'),
        );
      });
    }
  }

  Future<void> refreshSettings() async {
    await _loadBrightnessMode();
    if (!mounted) {
      return;
    }

    switch (_brightnessMode) {
      case BrightnessControlMode.auto:
        await _brightnessProvider.enableAutoMode();
        break;
      case BrightnessControlMode.manual:
        await _brightnessProvider.disableAutoMode();
        break;
      case BrightnessControlMode.none:
        await _brightnessProvider.cleanup();
        break;
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _buildMainContent();
  }

  Widget _buildMainContent() {
    if (_isLoading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_isRetrying)
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                CircularProgressIndicator(),
              SizedBox(height: 16),
              Text(
                _loadingStep,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
              if (_showRetryButton && !_isRetrying) ...[
                SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _retryWithLogin,
                  style: ElevatedButton.styleFrom(
                    minimumSize: Size(120, 36),
                  ),
                  child: Text('重试'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final secondaryColor = theme.colorScheme.secondary;

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            RefreshIndicator(
              onRefresh: () async {
                // 重置状态
                setState(() {
                  _isLoading = true;
                  _hasAttemptedAutoReservation = false;
                  _showRetryButton = false;
                  _nearbyBuses = [];
                  _cardStates = [];
                  _loadingStep = '正在刷新...';
                });

                // 重新启动慢加载计时器
                _startSlowLoadingTimer();

                // 重新初始化数据
                await _initialize();
              },
              child: SingleChildScrollView(
                physics: AlwaysScrollableScrollPhysics(), // 添加这一行以确保即使内容不足也能下拉
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: MediaQuery.of(context).size.height -
                        MediaQuery.of(context).padding.top -
                        kToolbarHeight,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        height: 600,
                        child: _nearbyBuses.isEmpty
                            ? Center(child: Text('无车可坐'))
                            : PageView.builder(
                                controller: _pageController,
                                itemCount: _nearbyBuses.length,
                                onPageChanged: (index) {
                                  if (index >= 0 &&
                                      index < _nearbyBuses.length) {
                                    _selectBus(index);
                                  }
                                },
                                itemBuilder: (context, index) {
                                  if (index < 0 ||
                                      index >= _cardStates.length) {
                                    return Center(child: Text('加载中...'));
                                  }
                                  return RideCard(
                                    cardState: _cardStates[index],
                                    isGoingToYanyuan: _isGoingToYanyuan,
                                    onMakeReservation: () =>
                                        _makeReservation(index),
                                    onCancelReservation: () =>
                                        _cancelReservation(index),
                                    isToggleLoading: _isToggleLoading,
                                  );
                                },
                              ),
                      ),
                      SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(
                            _nearbyBuses.length,
                            (index) => Container(
                              margin:
                                  const EdgeInsets.symmetric(horizontal: 4.0),
                              width: 8.0,
                              height: 8.0,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _selectedBusIndex == index
                                    ? primaryColor
                                    : secondaryColor
                                        .withAlpha((0.3 * 255).toInt()),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 只在手动模式下显示手电筒按钮
            if (_brightnessMode == BrightnessControlMode.manual)
              Positioned(
                right: 16,
                bottom: 16,
                child: Consumer<BrightnessProvider>(
                  builder: (context, brightnessProvider, _) {
                    return FloatingActionButton(
                      heroTag: 'flashlight',
                      onPressed: () => brightnessProvider.toggleFlashlight(),
                      child: Icon(
                        brightnessProvider.isFlashlightOn
                            ? Icons.flashlight_on
                            : Icons.flashlight_off,
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _makeReservation(int index, {int? generation}) async {
    if (generation != null && !_isCurrentInitialization(generation)) return;

    setState(() {
      _isToggleLoading = true;
      _cardStates[index]['errorMessage'] = '';
    });

    final bus = Map<String, dynamic>.from(_nearbyBuses[index]);
    final reservationService =
        ReservationService(Provider.of<AuthProvider>(context, listen: false));
    final reservationProvider =
        Provider.of<ReservationProvider>(context, listen: false);

    try {
      await reservationService.makeReservation(
        bus['bus_id'].toString(),
        bus['abscissa'],
        bus['time_id'].toString(),
      );
      if (generation != null && !_isCurrentInitialization(generation)) return;

      // 获取最新的预约列表
      await reservationProvider.loadCurrentReservations();
      if (generation != null && !_isCurrentInitialization(generation)) return;

      // 尝试匹配刚刚预约的班车
      Reservation? matchingReservation;
      try {
        matchingReservation =
            reservationProvider.currentReservations.firstWhere(
          (reservation) =>
              reservation.resourceName == bus['route_name'] &&
              reservation.appointmentTime ==
                  '${bus['abscissa']} ${bus['yaxis']}',
        );
      } catch (e) {
        matchingReservation = null;
      }

      if (matchingReservation != null) {
        // 获取乘车码
        if (generation == null) {
          await _fetchQRCode(reservationProvider, matchingReservation, index);
        } else {
          await _fetchQRCodeForInitialization(
            reservationService,
            matchingReservation,
            index,
            generation,
          );
        }
      } else {
        if (generation == null || _isCurrentInitialization(generation)) {
          setState(() {
            _cardStates[index]['errorMessage'] = '无法找到匹配的预约信息';
          });
        }
      }
    } catch (e) {
      if (generation == null || _isCurrentInitialization(generation)) {
        setState(() {
          _cardStates[index]['errorMessage'] = '预约失败: $e';
        });
      }
    } finally {
      if (mounted &&
          (generation == null || _isCurrentInitialization(generation))) {
        setState(() {
          _isToggleLoading = false;
        });
      }
    }
  }

  Future<void> _retryWithLogin() async {
    final now = DateTime.now();
    if (_lastRetryTime != null &&
        now.difference(_lastRetryTime!) < Duration(seconds: 3)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('请稍后再试'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    _lastRetryTime = now;

    if (_isRetrying) return;

    // 让仍在运行的旧初始化立即失效。
    _initializationGeneration++;

    if (!mounted) return;
    setState(() {
      _isRetrying = true;
      _loadingStep = '正在刷新登录状态...';
    });

    try {
      if (!mounted) return;
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      await authProvider.reloginWithSavedCredentials();

      if (!mounted) return;
      setState(() {
        _isLoading = true;
        _hasAttemptedAutoReservation = false;
        _showRetryButton = false;
        _nearbyBuses = [];
        _cardStates = [];
        _loadingStep = '正在重新加载数据...';
      });

      await _initialize();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadingStep = '重试失败: ${e.toString()}';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('重试失败: ${e.toString()}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isRetrying = false;
        });
      }
    }
  }
}
