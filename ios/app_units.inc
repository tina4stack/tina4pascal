{ Default: no project app-units. The iOS build (tools/tina4pascal proj_ios_stage)
  overwrites a staged copy of this file from tina4.json "appUnits", e.g.

      , Tina4CalcApp

  so the project's action-registering units link into libtina4ios.a. Each unit
  registers its named onclick actions in its own initialization, so the app's
  Pascal logic ships in the engine without editing this shared shell. Leaving it
  empty keeps the reference shell building on its own. The twin of
  android/jni/app_units.inc. }
