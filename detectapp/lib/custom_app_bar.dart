import 'package:flutter/material.dart';

class VisionBotAppBar extends StatelessWidget implements PreferredSizeWidget {
  final TabController tabController;
  final VoidCallback onSettingsPressed;
  final VoidCallback onSwitchCameraPressed;
  final VoidCallback onVerifyFacePressed;
  final bool isProcessingFace;

  const VisionBotAppBar({
    required this.tabController,
    required this.onSettingsPressed,
    required this.onSwitchCameraPressed,
    required this.onVerifyFacePressed,
    required this.isProcessingFace,
    super.key,
  });

  @override
  Size get preferredSize => const Size.fromHeight(120);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: const Text(
        'VisionBot',
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: Colors.white,
          letterSpacing: 0.5,
        ),
      ),
      flexibleSpace: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.orange.shade700, Colors.orange.shade600],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
      ),
      elevation: 4,
      toolbarHeight: 60,
      bottom: TabBar(
        controller: tabController,
        tabs: const [
          Tab(
            icon: Icon(Icons.videocam),
            text: 'Surveillance',
          ),
          Tab(
            icon: Icon(Icons.location_on),
            text: 'Location',
          ),
        ],
        labelColor: Colors.white,
        unselectedLabelColor: Colors.white60,
        indicatorColor: Colors.white,
        indicatorWeight: 3,
        indicatorSize: TabBarIndicatorSize.tab,
      ),
      actions: [
        IconButton(
          onPressed: onSettingsPressed,
          icon: const Icon(Icons.settings),
          tooltip: 'Detection Settings',
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        IconButton(
          onPressed: onSwitchCameraPressed,
          icon: const Icon(Icons.cameraswitch),
          tooltip: 'Switch Camera',
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        IconButton(
          onPressed: isProcessingFace ? null : onVerifyFacePressed,
          icon: const Icon(Icons.face),
          tooltip: 'Verify Face Now',
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
      ],
    );
  }
}
