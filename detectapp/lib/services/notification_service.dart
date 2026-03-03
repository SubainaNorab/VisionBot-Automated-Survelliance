// notification_service.dart - Push Notifications via FCM

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Background message handler (must be top-level function)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('📬 Background FCM message: ${message.messageId}');
}

class NotificationService {
  static NotificationService? _instance;
  static NotificationService get instance {
    _instance ??= NotificationService._();
    return _instance!;
  }

  NotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  String? _fcmToken;
  String? get fcmToken => _fcmToken;

  static const String _channelId = 'visionbot_alerts';
  static const String _channelName = 'VisionBot Security Alerts';
  static const String _channelDescription =
      'Alerts for unknown faces, group detection, and smoking';

  Future<void> initialize() async {
    debugPrint('🔔 Initializing NotificationService...');

    // Register background handler
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // Request notification permission
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    debugPrint('🔔 Notification permission: ${settings.authorizationStatus}');

    // Initialize local notifications
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );

    // Create high-priority notification channel for Android
    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDescription,
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );

    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    // Get FCM token and save to Firestore
    await _refreshToken();

    // Listen for token refresh
    _messaging.onTokenRefresh.listen((token) async {
      _fcmToken = token;
      await _saveTokenToFirestore(token);
      debugPrint('🔔 FCM Token refreshed: ${token.substring(0, 20)}...');
    });

    // Handle foreground messages
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    debugPrint('✅ NotificationService initialized');
  }

  Future<void> _refreshToken() async {
    try {
      _fcmToken = await _messaging.getToken();
      if (_fcmToken != null) {
        debugPrint('🔔 FCM Token: ${_fcmToken!.substring(0, 20)}...');
        await _saveTokenToFirestore(_fcmToken!);
      }
    } catch (e) {
      debugPrint('⚠️ Failed to get FCM token: $e');
    }
  }

  Future<void> _saveTokenToFirestore(String token) async {
    try {
      await FirebaseFirestore.instance
          .collection('device_tokens')
          .doc('surveillance_device')
          .set({
        'token': token,
        'updated_at': FieldValue.serverTimestamp(),
        'platform': defaultTargetPlatform.toString(),
      }, SetOptions(merge: true));
      debugPrint('✅ FCM token saved to Firestore');
    } catch (e) {
      debugPrint('⚠️ Failed to save FCM token: $e');
    }
  }

  void _handleForegroundMessage(RemoteMessage message) {
    debugPrint('📬 Foreground FCM message: ${message.notification?.title}');
    _showLocalNotification(
      title: message.notification?.title ?? 'VisionBot Alert',
      body: message.notification?.body ?? '',
      payload: json.encode(message.data),
    );
  }

  void _onNotificationTap(NotificationResponse response) {
    debugPrint('🔔 Notification tapped: ${response.payload}');
    // Handle navigation here if needed
  }

  /// Show local notification immediately (for foreground use)
  Future<void> _showLocalNotification({
    required String title,
    required String body,
    String? payload,
    String? imageUrl,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
      icon: '@mipmap/ic_launcher',
      largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
      styleInformation:
          imageUrl != null ? null : const BigTextStyleInformation(''),
      enableLights: true,
      enableVibration: true,
      color: const Color(0xFFFF5252),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
      payload: payload,
    );
  }

  /// Send unknown face alert notification
  Future<void> sendUnknownFaceNotification({
    required double latitude,
    required double longitude,
    required String placeName,
    required String timestamp,
    String? imagePath,
    int unknownCount = 1,
  }) async {
    debugPrint('');
    debugPrint('═══════════════════════════════════');
    debugPrint('🔔 SENDING UNKNOWN FACE NOTIFICATION');
    debugPrint('═══════════════════════════════════');
    debugPrint('   Place: $placeName');
    debugPrint('   Location: $latitude, $longitude');
    debugPrint('   Count: $unknownCount');

    final title = '🚨 Unknown Person Detected!';
    final body = unknownCount > 1
        ? '$unknownCount unknown people detected at $placeName'
        : 'Unknown person detected at $placeName';

    // Show immediate local notification (works even when app is in foreground)
    await _showLocalNotification(
      title: title,
      body: body,
      payload: json.encode({
        'type': 'unknown_face',
        'latitude': latitude,
        'longitude': longitude,
        'place_name': placeName,
        'timestamp': timestamp,
      }),
    );

    // Also store notification in Firestore for the viewer app to pick up
    await _storeNotificationRecord(
      title: title,
      body: body,
      type: 'unknown_face',
      latitude: latitude,
      longitude: longitude,
      placeName: placeName,
      timestamp: timestamp,
      imagePath: imagePath,
      unknownCount: unknownCount,
    );

    debugPrint('✅ Unknown face notification sent');
    debugPrint('═══════════════════════════════════');
    debugPrint('');
  }

  /// Send group detection notification
  Future<void> sendGroupNotification({
    required int personCount,
    required double latitude,
    required double longitude,
    required String placeName,
    required String timestamp,
  }) async {
    final title = '👥 Group Detected!';
    final body = '$personCount people detected at $placeName';

    await _showLocalNotification(
      title: title,
      body: body,
    );

    await _storeNotificationRecord(
      title: title,
      body: body,
      type: 'group_detected',
      latitude: latitude,
      longitude: longitude,
      placeName: placeName,
      timestamp: timestamp,
    );

    debugPrint('✅ Group notification sent: $personCount at $placeName');
  }

  /// Send smoking detection notification
  Future<void> sendSmokingNotification({
    required double latitude,
    required double longitude,
    required String placeName,
    required String timestamp,
  }) async {
    final title = '🚬 Smoking Detected!';
    final body = 'Smoking activity detected at $placeName';

    await _showLocalNotification(
      title: title,
      body: body,
    );

    await _storeNotificationRecord(
      title: title,
      body: body,
      type: 'smoking_detected',
      latitude: latitude,
      longitude: longitude,
      placeName: placeName,
      timestamp: timestamp,
    );

    debugPrint('✅ Smoking notification sent at $placeName');
  }

  Future<void> _storeNotificationRecord({
    required String title,
    required String body,
    required String type,
    required double latitude,
    required double longitude,
    required String placeName,
    required String timestamp,
    String? imagePath,
    int? unknownCount,
  }) async {
    try {
      await FirebaseFirestore.instance.collection('notifications').add({
        'title': title,
        'body': body,
        'type': type,
        'latitude': latitude,
        'longitude': longitude,
        'place_name': placeName,
        'timestamp': timestamp,
        'created_at': FieldValue.serverTimestamp(),
        'image_path': imagePath,
        'unknown_count': unknownCount,
        'is_read': false,
      });
      debugPrint('✅ Notification record stored in Firestore');
    } catch (e) {
      debugPrint('⚠️ Failed to store notification record: $e');
    }
  }
}
