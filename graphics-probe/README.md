# Liberty Test Lab

The unified app uses bundle identifier `com.libertydiagnostics.vulkanprobe`, matching the earlier Vulkan test app. Keep Signulous signing identity and bundle identifier settings consistent to install this as an update. Do not uninstall first if you want to retain the Vulkan app's saved log. Re-signing under a different identity or changing the identifier may affect update compatibility.

The app contains native Metal display, Documents storage, audio tone, actual RexGlue runtime memory, thread/event/semaphore and fibre tests, plus the official MoltenVK SPIR-V triangle/readback/presentation test. Run checks individually. All results share one persistent log, available through Share combined log. The earlier Vulkan log is migrated on first launch; logs from the separate earlier apps are in their own sandboxes and cannot be imported automatically.

Future native tests will be added to this same app. Native code changes require an updated IPA to be installed. No game code or assets are included.

Use Actions > Build Liberty Test Lab IPA, download LibertyTestLab-unsigned-IPA and extract the outer ZIP before uploading the IPA to Signulous. The internal executable remains named VulkanProbe; the installed display name is Liberty Test Lab.

Tests establish only their logged scope. This is not yet the full LibertyRecomp renderer or title application.
