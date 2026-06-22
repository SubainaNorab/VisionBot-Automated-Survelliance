// ble_navigation_service.dart
// Handles BLE connection to ESP32 and sends navigation commands
// FIXED: Auto-reconnect on disconnect + keepalive timer

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
  BluetoothCharacteristic? _rxChar;
  BluetoothCharacteristic? _txChar;

  final StreamController<String> _statusController =
      StreamController<String>.broadcast();
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();

  // Reconnect state
  bool _intentionalDisconnect = false;
  bool _reconnecting = false;
  Timer? _keepaliveTimer;
  Timer? _reconnectTimer;
  static const int _keepaliveIntervalMs = 10000; // ping every 10s
  static const int _reconnectDelayMs = 3000;     // wait 3s before retry

  Stream<String> get statusStream => _statusController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;
  bool get isConnected => _device != null && _rxChar != null;

  bool _isLikelyTargetDevice(BluetoothDevice device, String? name) {
    final normalizedName = (name ?? device.platformName).toLowerCase();
    return normalizedName.contains('aiwatchman') ||
        normalizedName.contains('watchman') ||
        normalizedName.contains('esp32') ||
        normalizedName.contains('car');
  }

  bool _advertisesTargetService(ScanResult result) {
    return result.advertisementData.serviceUuids.any(
      (uuid) => uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase(),
    );
  }

  /// Scan and connect to AIWatchman-Car
  Future<bool> connect() async {
    _intentionalDisconnect = false;
    return _connectInternal();
  }

  Future<bool> _connectInternal() async {
    try {
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        debugPrint('[BLE] Bluetooth is OFF: $adapterState');
        return false;
      }
      debugPrint('[BLE] Starting scan for AIWatchman-Car...');

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));

      final completer = Completer<BluetoothDevice>();
      final discoveredNames = <String>{};
      BluetoothDevice? fallbackDevice;

      final sub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final deviceName = r.device.platformName;
          if (deviceName.isNotEmpty) {
            discoveredNames.add(deviceName);
          }

          fallbackDevice ??= r.device;

          final isTarget = _isLikelyTargetDevice(r.device, deviceName) ||
              _advertisesTargetService(r);
          if (isTarget && !completer.isCompleted) {
            debugPrint('[BLE] Candidate device found: ${r.device.remoteId}');
            completer.complete(r.device);
          }
        }
      });

      BluetoothDevice device;
      try {
        device = await completer.future.timeout(const Duration(seconds: 12));
      } catch (_) {
        if (fallbackDevice != null) {
          device = fallbackDevice!;
        } else {
          sub.cancel();
          await FlutterBluePlus.stopScan();
          return false;
        }
      }

      sub.cancel();
      await FlutterBluePlus.stopScan();

      await device.connect(timeout: const Duration(seconds: 10));
      _device = device;
      debugPrint('[BLE] Connected to ${device.platformName}');

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

      // Watch for disconnect — auto-reconnect unless intentional
      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          debugPrint('[BLE] Disconnected');
          _rxChar = null;
          _txChar = null;
          _device = null;
          _stopKeepalive();
          _connectionController.add(false);

          if (!_intentionalDisconnect && !_reconnecting) {
            _scheduleReconnect();
          }
        }
      });

      _connectionController.add(true);
      _startKeepalive();
      return true;
    } catch (e) {
      debugPrint('[BLE] Connect error: $e');
      return false;
    }
  }

  // ── Keepalive ─────────────────────────────────────────────────────────────
  // Sends a no-op ping so Android doesn't kill the idle connection.
  // 'S' (stop) is safe when the car is already stopped; change to a
  // dedicated ping byte if your ESP32 firmware supports one.

  void _startKeepalive() {
    _stopKeepalive();
    _keepaliveTimer =
        Timer.periodic(const Duration(milliseconds: _keepaliveIntervalMs), (_) async {
      if (isConnected) {
        try {
          // Write with response=false; won't move the car but keeps link alive
          await _rxChar!.write(utf8.encode('S'), withoutResponse: false);
          debugPrint('[BLE] Keepalive ping sent');
        } catch (e) {
          debugPrint('[BLE] Keepalive failed: $e');
        }
      }
    });
  }

  void _stopKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
  }

  // ── Auto-reconnect ────────────────────────────────────────────────────────

  void _scheduleReconnect() {
    if (_reconnecting || _intentionalDisconnect) return;
    _reconnecting = true;
    debugPrint('[BLE] Reconnect scheduled in ${_reconnectDelayMs}ms…');

    _reconnectTimer?.cancel();
    _reconnectTimer =
        Timer(const Duration(milliseconds: _reconnectDelayMs), () async {
      if (_intentionalDisconnect) {
        _reconnecting = false;
        return;
      }
      debugPrint('[BLE] Attempting reconnect…');
      final ok = await _connectInternal();
      _reconnecting = false;
      if (!ok && !_intentionalDisconnect) {
        // Back-off and try again
        debugPrint('[BLE] Reconnect failed, retrying in 5s…');
        _reconnectTimer = Timer(const Duration(seconds: 5), () {
          if (!_intentionalDisconnect && !isConnected) {
            _scheduleReconnect();
          }
        });
      }
    });
  }

  // ── Commands ──────────────────────────────────────────────────────────────

  /// Send single-char command: F, L, R, S, E
  Future<void> sendCommand(String cmd) async {
    if (_rxChar == null) {
      debugPrint('[BLE] Not connected, cannot send $cmd');
      return;
    }
    try {
      // withoutResponse: false — ensures delivery acknowledgement from ESP32
      await _rxChar!.write(utf8.encode(cmd), withoutResponse: false);
      debugPrint('[BLE] Sent: $cmd');
    } catch (e) {
      debugPrint('[BLE] Send error: $e');
    }
  }

  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _stopKeepalive();
    await sendCommand('S'); // stop car before disconnect
    await _device?.disconnect();
    _rxChar = null;
    _txChar = null;
    _device = null;
  }

  void dispose() {
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _stopKeepalive();
    _statusController.close();
    _connectionController.close();
  }
}