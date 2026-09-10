#!/usr/bin/env python3
"""Apply the Phase-1 watchOS-Simulator (aarch64) target to an FPC source tree.
Idempotent-ish: aborts if the marker enum is already present."""
import re, sys, os

FS = os.path.dirname(os.path.abspath(__file__)) + "/fpcsrc"
C = FS + "/compiler"

def edit(path, old, new, count=1, must=True):
    p = os.path.join(C, path)
    s = open(p).read()
    n = s.count(old)
    if n == 0:
        if must: sys.exit(f"NOT FOUND in {path}:\n{old[:200]}")
        print(f"  skip (absent) {path}")
        return
    if count and n != count:
        sys.exit(f"expected {count} got {n} of pattern in {path}:\n{old[:120]}")
    s = s.replace(old, new)
    open(p, "w").write(s)
    print(f"  patched {path} ({n})")

# 0. guard
if "system_aarch64_watchossim" in open(C+"/systems.inc").read():
    sys.exit("already patched")

# 1. enum ------------------------------------------------------------------
edit("systems.inc",
     "             system_aarch64_iphonesim,  { 121 }\n",
     "             system_aarch64_iphonesim,  { 121 }\n"
     "             system_aarch64_watchossim, { 127 }\n")

# 2. i_darwin.pas: clone the record ---------------------------------------
p = C + "/systems/i_darwin.pas"
s = open(p).read()
m = re.search(r"   system_aarch64_iphonesim_info  : tsysteminfo =\n(.*?\n      \);\n)",
              s, re.S)
if not m: sys.exit("iphonesim record not found")
rec = m.group(0)
clone = (rec
         .replace("system_aarch64_iphonesim_info  : tsysteminfo",
                  "system_aarch64_watchossim_info : tsysteminfo")
         .replace("system       : system_aarch64_iphonesim;",
                  "system       : system_aarch64_watchossim;")
         .replace("name         : 'Darwin/iPhoneSim for AArch64';",
                  "name         : 'Darwin/watchOS Simulator for AArch64';")
         .replace("shortname    : 'iPhoneSim';",
                  "shortname    : 'watchOSSim';"))
s = s.replace(rec, rec + "\n" + clone)
open(p, "w").write(s)
print("  patched systems/i_darwin.pas (record clone)")

# 3. systems.pas: sets -----------------------------------------------------
edit("systems.pas",
  "       systems_iphonesim = [system_i386_iphonesim,system_x86_64_iphonesim,system_aarch64_iphonesim];",
  "       systems_iphonesim = [system_i386_iphonesim,system_x86_64_iphonesim,system_aarch64_iphonesim];\n"
  "       systems_watchossim = [system_aarch64_watchossim];")
edit("systems.pas",
  "       systems_darwin = systems_ios + systems_iphonesim + systems_macosx;",
  "       systems_darwin = systems_ios + systems_iphonesim + systems_watchossim + systems_macosx;")
edit("systems.pas",
  "systems_objc_nfabi = [system_powerpc64_darwin,system_x86_64_darwin,system_arm_ios,system_i386_iphonesim,system_aarch64_ios,system_aarch64_darwin,system_x86_64_iphonesim,system_aarch64_iphonesim];",
  "systems_objc_nfabi = [system_powerpc64_darwin,system_x86_64_darwin,system_arm_ios,system_i386_iphonesim,system_aarch64_ios,system_aarch64_darwin,system_x86_64_iphonesim,system_aarch64_iphonesim,system_aarch64_watchossim];",
  count=1)
edit("systems.pas",
  "systems_caller_copy_addr_value_para = [system_aarch64_ios,system_aarch64_iphonesim,",
  "systems_caller_copy_addr_value_para = [system_aarch64_ios,system_aarch64_iphonesim,system_aarch64_watchossim,")

# 4. aggas.pas: darwin .section group -------------------------------------
edit("aggas.pas",
  "         system_aarch64_iphonesim,\n         system_aarch64_darwin,\n         system_x86_64_iphonesim,",
  "         system_aarch64_iphonesim,\n         system_aarch64_watchossim,\n         system_aarch64_darwin,\n         system_x86_64_iphonesim,")

# 5. objcgutl.pas ----------------------------------------------------------
edit("objcgutl.pas",
  "system_x86_64_iphonesim,system_aarch64_iphonesim]) then",
  "system_x86_64_iphonesim,system_aarch64_iphonesim,system_aarch64_watchossim]) then")

# 6. options.pas -----------------------------------------------------------
# 6a env-var gate (line ~1387)
edit("options.pas",
  "if not(target_info.system in [system_i386_iphonesim,system_arm_ios,system_aarch64_ios,system_x86_64_iphonesim,system_aarch64_iphonesim]) then\n    begin\n      envstr:=GetEnvironmentVariable('MACOSX_DEPLOYMENT_TARGET');",
  "if not(target_info.system in [system_i386_iphonesim,system_arm_ios,system_aarch64_ios,system_x86_64_iphonesim,system_aarch64_iphonesim,system_aarch64_watchossim]) then\n    begin\n      envstr:=GetEnvironmentVariable('MACOSX_DEPLOYMENT_TARGET');")
# 6b default version-min case (line ~1442)
edit("options.pas",
  "    system_aarch64_iphonesim:\n      begin\n        if not ParseMacVersionMin(iPhoneOSVersionMin,MacOSXVersionMin,'IPHONE_OS_VERSION_MIN_REQUIRED','14.0.0',false) then\n          internalerror(2023032201);\n      end;",
  "    system_aarch64_iphonesim:\n      begin\n        if not ParseMacVersionMin(iPhoneOSVersionMin,MacOSXVersionMin,'IPHONE_OS_VERSION_MIN_REQUIRED','14.0.0',false) then\n          internalerror(2023032201);\n      end;\n    system_aarch64_watchossim:\n      begin\n        if not ParseMacVersionMin(iPhoneOSVersionMin,MacOSXVersionMin,'IPHONE_OS_VERSION_MIN_REQUIRED','10.0.0',false) then\n          internalerror(2026091001);\n      end;")
# 6c line ~4083 (systems_darwin - [sim list])
edit("options.pas",
  "(systems_darwin-[system_i386_iphonesim,system_arm_ios,system_aarch64_ios,system_x86_64_iphonesim,system_aarch64_iphonesim])) and",
  "(systems_darwin-[system_i386_iphonesim,system_arm_ios,system_aarch64_ios,system_x86_64_iphonesim,system_aarch64_iphonesim,system_aarch64_watchossim])) and")
# 6d line ~4127
edit("options.pas",
  "in [system_i386_iphonesim,system_arm_ios,system_aarch64_ios,system_x86_64_iphonesim,system_aarch64_iphonesim]) and",
  "in [system_i386_iphonesim,system_arm_ios,system_aarch64_ios,system_x86_64_iphonesim,system_aarch64_iphonesim,system_aarch64_watchossim]) and")

# 7. symdef.pas:9669 -------------------------------------------------------
edit("symdef.pas",
  "if not(target_info.system in [system_arm_ios,system_i386_iphonesim,system_aarch64_ios,system_x86_64_iphonesim,system_aarch64_iphonesim]) then",
  "if not(target_info.system in [system_arm_ios,system_i386_iphonesim,system_aarch64_ios,system_x86_64_iphonesim,system_aarch64_iphonesim,system_aarch64_watchossim]) then")

# 8. triplet.pas:49 (equality -> set) --------------------------------------
edit("triplet.pas",
  "else if target_info.system = system_aarch64_iphonesim then\n            result:=result+'-ios-simulator'+iPhoneOSVersionMin.str",
  "else if target_info.system in [system_aarch64_iphonesim,system_aarch64_watchossim] then\n            result:=result+'-ios-simulator'+iPhoneOSVersionMin.str")

# 9. aarch64/agcpugas.pas:892 supported_targets ----------------------------
edit("aarch64/agcpugas.pas",
  "supported_targets : [system_aarch64_ios,system_aarch64_darwin,system_aarch64_iphonesim];",
  "supported_targets : [system_aarch64_ios,system_aarch64_darwin,system_aarch64_iphonesim,system_aarch64_watchossim];")

# 10. t_darwin.pas ---------------------------------------------------------
# 10a GetLinkArch arm64
edit("systems/t_darwin.pas",
  "          system_aarch64_ios,\n          system_aarch64_iphonesim,\n          system_aarch64_darwin:\n            result:='-arch arm64';",
  "          system_aarch64_ios,\n          system_aarch64_iphonesim,\n          system_aarch64_watchossim,\n          system_aarch64_darwin:\n            result:='-arch arm64';")
# 10b GetLinkVersion sim flag
edit("systems/t_darwin.pas",
  "if target_info.system in [system_i386_iphonesim,system_x86_64_iphonesim,system_aarch64_iphonesim] then\n              result:='-ios_simulator_version_min '+iPhoneOSVersionMin.str",
  "if target_info.system=system_aarch64_watchossim then\n              result:='-watchos_simulator_version_min '+iPhoneOSVersionMin.str\n            else if target_info.system in [system_i386_iphonesim,system_x86_64_iphonesim,system_aarch64_iphonesim] then\n              result:='-ios_simulator_version_min '+iPhoneOSVersionMin.str")
# 10c the three CreateOrderedSymbols / crt blocks (205,258,298) each list the sims
for anchor in [
  "                  system_i386_iphonesim,\n                  system_x86_64_iphonesim,\n                  system_aarch64_iphonesim:"]:
    edit("systems/t_darwin.pas",
         anchor,
         anchor.replace("system_aarch64_iphonesim:",
                        "system_aarch64_iphonesim,\n                  system_aarch64_watchossim:"),
         count=3)
# 10e RegisterTarget block (clone the aarch64_iphonesim registration)
edit("systems/t_darwin.pas",
  "  RegisterImport(system_aarch64_iphonesim,timportlibdarwin);\n"
  "  RegisterExport(system_aarch64_iphonesim,texportlibdarwin);\n"
  "  RegisterTarget(system_aarch64_iphonesim_info);",
  "  RegisterImport(system_aarch64_iphonesim,timportlibdarwin);\n"
  "  RegisterExport(system_aarch64_iphonesim,texportlibdarwin);\n"
  "  RegisterTarget(system_aarch64_iphonesim_info);\n"
  "  RegisterImport(system_aarch64_watchossim,timportlibdarwin);\n"
  "  RegisterExport(system_aarch64_watchossim,texportlibdarwin);\n"
  "  RegisterTarget(system_aarch64_watchossim_info);")

print("ALL PATCHES APPLIED")
