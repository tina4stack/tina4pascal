{ Default: no project app-units. The android build (tools/tina4pascal.ps1)
  overwrites a staged copy of this file from tina4.json "appUnits", e.g.

      , Tina4CalcApp

  so the project's action-registering units link into libtina4.so. Leaving this
  empty keeps the reference shell building on its own. }
