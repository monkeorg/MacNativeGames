# Upstream iOS display and thermal integration

Source audit: upstream [`d259f83dd72db768a95a2caf031516cee3367b0f`](https://github.com/ly05010419/MacNativeGames/commit/d259f83dd72db768a95a2caf031516cee3367b0f), “iPhone / iPad fill the screen and run at 30 fps; the thermal state is logged.”

The isolated strong `dm_thermal_now()` hook is reused in `games/totk/runtime/frontend_ios.m`. It returns the actual `NSProcessInfo.thermalState` enum: 0 nominal, 1 fair, 2 serious, 3 critical. Existing NVN summary logs already call this hook; without the iOS definition they use the weak fallback `-1`. This is a process/system thermal observation, not measured GPU temperature, a performance result or a new throttling policy. The Mac implementation is unchanged.

The other upstream defaults are not imported:

- **30 FPS default:** this branch already has supported live 30/40/60 FPS choices. Its effective deadline combines the existing pacing period with the live ceiling. Changing the cached uncapped default to 30 would prevent a saved or live 40/60 selection from shortening that deadline. The display-rate fallback and explicit developer overrides remain intact.
- **Automatic fullscreen:** upstream fits the camera to the drawable while retaining a 1280×720 canvas. This branch keeps the selected render/output canvas, full embedded-stub and Vert+ checks, 16:9 default, and the capability-gated experimental exact-4:3 layout. Existing profile-gated aspect notifications remain unchanged. Unconditional fullscreen would not establish 1080-high rendering or verified UI layout.

No language, menu, preference, save/account identity, executable profile, address table or Mac rendering behavior changes are included. Upstream records build/install evidence but explicitly leaves phone-picture confirmation open; that is not new acceptance evidence for this integration.

This checkpoint is source-only. No tests, probes, compiler checks, new test files, builds, installations, private inputs or device operations ran. Apple compilation and physical thermal-log observation remain unverified here.
