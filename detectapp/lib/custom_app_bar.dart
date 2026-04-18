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
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      backgroundColor: Colors.red, // Red background to check visibility
      elevation: 8,
      toolbarHeight: 60,
      bottom: TabBar(
        controller: tabController,
        tabs: const [
          Tab(
            icon: Icon(Icons.videocam, color: Colors.white),
            text: 'Surveillance',
          ),
          Tab(
            icon: Icon(Icons.location_on, color: Colors.white),
            text: 'Location',
          ),
        ],
        labelColor: Colors.white,
        unselectedLabelColor: Colors.grey.shade400,
        indicatorColor: Colors.cyan,
        indicatorSize: TabBarIndicatorSize.tab,
      ),
      actions: [
        IconButton(
          onPressed: onSettingsPressed,
          icon: const Icon(Icons.settings, size: 20),
          tooltip: 'Detection Settings',
          padding: const EdgeInsets.all(8),
        ),
        IconButton(
          onPressed: onSwitchCameraPressed,
          icon: const Icon(Icons.cameraswitch, size: 20),
          tooltip: 'Switch Camera',
          padding: const EdgeInsets.all(8),
        ),
        IconButton(
          onPressed: isProcessingFace ? null : onVerifyFacePressed,
          icon: const Icon(Icons.face, size: 20),
          tooltip: 'Verify Face Now',
          padding: const EdgeInsets.all(8),
        ),
      ],
    );
  }
}
