import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:marchkov_helper/models/reservation.dart';
import 'package:marchkov_helper/providers/auth_provider.dart';
import 'package:marchkov_helper/providers/brightness_provider.dart';
import 'package:marchkov_helper/providers/reservation_provider.dart';
import 'package:marchkov_helper/providers/ride_history_provider.dart';
import 'package:marchkov_helper/screens/ride/ride_page.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestAuthProvider extends AuthProvider {
  @override
  Future<void> reloginWithSavedCredentials() async {}
}

class _SlowReservationProvider extends ReservationProvider {
  _SlowReservationProvider(super.authProvider);

  final Completer<void> _firstLoad = Completer<void>();
  int _loadCount = 0;

  @override
  List<Reservation> get currentReservations => const [];

  @override
  Future<void> loadCurrentReservations() async {
    _loadCount++;
    if (_loadCount == 1) {
      await _firstLoad.future;
    }
  }

  void releaseFirstLoad() {
    if (!_firstLoad.isCompleted) {
      _firstLoad.complete();
    }
  }
}

class _TestRideHistoryProvider extends RideHistoryProvider {
  _TestRideHistoryProvider(super.authProvider);

  @override
  Future<void> loadRideHistory() async {}
}

Map<String, dynamic> _busAt(DateTime departure, int id) {
  return {
    'route_name': '新燕园-燕园测试线$id',
    'bus_id': id,
    'abscissa': DateFormat('yyyy-MM-dd').format(departure),
    'yaxis': DateFormat('HH:mm').format(departure),
    'row': {'margin': 1, 'status': 1},
    'time_id': id,
    'status': 1,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('stale initialization cannot leave swipeable loading cards',
      (tester) async {
    final now = DateTime.now();
    final today = DateFormat('yyyy-MM-dd').format(now);
    SharedPreferences.setMockInitialValues({
      'cachedDate': today,
      'cachedBusData': json.encode([
        _busAt(now.add(const Duration(minutes: 5)), 1),
        _busAt(now.add(const Duration(minutes: 10)), 2),
      ]),
      'autoReservationEnabled': false,
    });

    final authProvider = _TestAuthProvider();
    final reservationProvider = _SlowReservationProvider(authProvider);
    final rideHistoryProvider = _TestRideHistoryProvider(authProvider);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
          ChangeNotifierProvider<ReservationProvider>.value(
            value: reservationProvider,
          ),
          ChangeNotifierProvider<RideHistoryProvider>.value(
            value: rideHistoryProvider,
          ),
          ChangeNotifierProvider<BrightnessProvider>(
            create: (_) => BrightnessProvider(),
          ),
        ],
        child: const MaterialApp(home: RidePage()),
      ),
    );

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('加载中...'), findsNothing);
    expect(find.text('待预约'), findsWidgets);

    reservationProvider.releaseFirstLoad();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('加载中...'), findsNothing);
    expect(find.text('待预约'), findsWidgets);
  });
}
