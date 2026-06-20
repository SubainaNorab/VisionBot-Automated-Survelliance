// ble_navigation_service.dart
// Handles BLE connection to ESP32 and sends navigation commands

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BleNavigationService {
  // Nordic UART Service UUIDs — must match ESP32 code
  static const String SERVICE_UUID = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const String RX_CHAR_UUID =
      '6e400002-b5a3-f393-e0a9-e50e24dcca9e'; // App writes here
  static const String TX_CHAR_UUID =
      '6e400003-b5a3-f393-e0a9-e50e24dcca9e'; // App reads notifications

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxChar; // write commands to car
  BluetoothCharacteristic? _txChar; // receive status from car

  final StreamController<String> _statusController =
      StreamController<String>.broadcast();
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();

  Stream<String> get statusStream => _statusController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;
  bool get isConnected => _device != null && (_rxChar != null);

  /// Scan and connect to AIWatchman-Car
  Future<bool> connect() async {
    try {
      debugPrint('[BLE] Starting scan for AIWatchman-Car...');

      // Start scan
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

      // Wait for our device
      final completer = Completer<BluetoothDevice>();
      final discoveredNames = <String>{};

      final sub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final deviceName = r.device.platformName;
          if (deviceName.isNotEmpty) {
            discoveredNames.add(deviceName);
            debugPrint('[BLE] Discovered: "$deviceName" (RSSI: ${r.rssi})');
          }

          if (r.device.platformName == 'AIWatchman-Car') {
            debugPrint('[BLE] ✅ Found AIWatchman-Car!');
            if (!completer.isCompleted) completer.complete(r.device);
          }
        }
      });

      BluetoothDevice device;
      try {
        device = await completer.future.timeout(const Duration(seconds: 10));
      } catch (_) {
        debugPrint('[BLE] ❌ Device not found in scan');
        if (discoveredNames.isNotEmpty) {
          debugPrint('[BLE] ℹ️  Devices found: ${discoveredNames.join(", ")}');
          debugPrint('[BLE] ℹ️  Looking for: "AIWatchman-Car"');
        } else {
          debugPrint('[BLE] ⚠️  No BLE devices discovered!');
          debugPrint('[BLE]    - Check if Bluetooth is enabled');
          debugPrint('[BLE]    - Check if ESP32 is powered on and advertising');
          debugPrint('[BLE]    - Check app has BLUETOOTH_SCAN permission');
        }
        sub.cancel();
        await FlutterBluePlus.stopScan();
        return false;
      }

      sub.cancel();
      await FlutterBluePlus.stopScan();

      // Connect
      await device.connect(timeout: const Duration(seconds: 10));
      _device = device;
      debugPrint('[BLE] Connected to ${device.platformName}');

      // Discover services
      final services = await device.discoverServices();

      for (final s in services) {
        if (s.uuid.toString().toLowerCase() == SERVICE_UUID) {
          for (final c in s.characteristics) {
            final uuid = c.uuid.toString().toLowerCase();
            if (uuid == RX_CHAR_UUID) {
              _rxChar = c;
              debugPrint('[BLE] RX characteristic found');
            }
            if (uuid == TX_CHAR_UUID) {
              _txChar = c;
              // Subscribe to notifications (Arduino status: BLOCKED/CLEAR)
              await c.setNotifyValue(true);
              c.lastValueStream.listen((value) {
                final msg = utf8.decode(value).trim();
                if (msg.isNotEmpty) {
                  debugPrint('[BLE] Status from car: $msg');
                  _statusController.add(msg);
                }
              });
              debugPrint('[BLE] TX characteristic found, notifications on');
            }
          }
        }
      }

      if (_rxChar == null) {
        debugPrint('[BLE] RX characteristic not found!');
        return false;
      }

      // Watch for disconnect
      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          debugPrint('[BLE] Disconnected');
          _rxChar = null;
          _txChar = null;
          _device = null;
          _connectionController.add(false);
        }
      });

      _connectionController.add(true);
      return true;
    } catch (e) {
      debugPrint('[BLE] Connect error: $e');
      return false;
    }
  }

  /// Send single-char command: F, L, R, S, E
  Future<void> sendCommand(String cmd) async {
    if (_rxChar == null) {
      debugPrint('[BLE] Not connected, cannot send $cmd');
      return;
    }
    try {
      await _rxChar!.write(utf8.encode(cmd), withoutResponse: true);
      debugPrint('[BLE] Sent: $cmd');
    } catch (e) {
      debugPrint('[BLE] Send error: $e');
    }
  }

  Future<void> disconnect() async {
    await sendCommand('S'); // stop car before disconnect
    await _device?.disconnect();
    _rxChar = null;
    _txChar = null;
    _device = null;
  }

  void dispose() {
    _statusController.close();
    _connectionController.close();
  }
}
