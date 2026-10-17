#!/usr/bin/env python3
"""
Generate a complete Xcode project.pbxproj for the QixiangPayMonitor iOS app.
This avoids the need for XcodeGen and gives full control over the project structure.
(CI 工程真源 —— project.yml/xcodegen 不参与构建)
"""
import os
import hashlib

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(BASE_DIR, "QixiangPayMonitor")

# Collect all Swift files and Info.plist
swift_files = []
plist_files = []
for root, dirs, files in os.walk(SRC_DIR):
    for f in sorted(files):
        full = os.path.join(root, f)
        rel = os.path.relpath(full, BASE_DIR).replace("\\", "/")
        if f.endswith(".swift"):
            swift_files.append(rel)
        elif f == "Info.plist":
            plist_files.append(rel)

print(f"Found {len(swift_files)} Swift files and {len(plist_files)} plist files:")
for sf in swift_files:
    print(f"  {sf}")
for pf in plist_files:
    print(f"  {pf}")

# 顶层资源目录（.xcassets → Resources phase 编译为 Assets.car）
xcassets = [d for d in sorted(os.listdir(SRC_DIR))
            if d.endswith(".xcassets") and os.path.isdir(os.path.join(SRC_DIR, d))]
for xc in xcassets:
    print(f"  QixiangPayMonitor/{xc} (asset catalog)")

# Generate unique 24-char hex IDs
def gen_id(seed):
    h = hashlib.md5(seed.encode()).hexdigest()
    return h[:24].upper()

# Build PBXFileReference and PBXBuildFile entries
file_refs = {}
build_files = {}
groups = {}  # group path -> (group_id, children_ids)

def ensure_group(path_parts):
    """Create (or fetch) the group for path_parts, recursively attaching it
    to its parent group's children."""
    if not path_parts:
        return root_gid
    key = "/".join(path_parts)
    if key in groups:
        return groups[key][0]

    gid = gen_id("group:" + key)
    children = []
    groups[key] = (gid, children)

    parent_key = "/".join(path_parts[:-1])
    parent_gid = ensure_group(path_parts[:-1])
    groups[parent_key][1].append(gid)
    return gid

# Root group
root_gid = gen_id("group:ROOT")
groups[""] = (root_gid, [])

# Process files
# NOTE: Info.plist must NOT get a PBXBuildFile entry and must NOT be in any
# build phase. INFOPLIST_FILE handles it via ProcessInfoPlistFile.
all_files = swift_files + plist_files
for f in all_files:
    fid = gen_id("file:" + f)
    file_refs[f] = fid

    if f.endswith(".swift"):
        bid = gen_id("build:" + f)
        build_files[f] = bid

    parts = f.split("/")
    parent_parts = parts[:-1]
    ensure_group(parent_parts)
    parent_key = "/".join(parent_parts)
    groups[parent_key][1].append(fid)

# xcassets：FileReference + PBXBuildFile(Resources) + 挂到 QixiangPayMonitor 组
# key 带目录前缀，basename 作为组内 path（组已有 path=QixiangPayMonitor）
for xc in xcassets:
    key = "QixiangPayMonitor/" + xc
    fid = gen_id("file:" + key)
    file_refs[key] = fid
    build_files[key] = gen_id("build:" + key)
    ensure_group(["QixiangPayMonitor"])
    groups["QixiangPayMonitor"][1].append(fid)

# Generate project.pbxproj content
lines = []
lines.append("// !$*UTF8*$!")
lines.append("{")
lines.append("\tarchiveVersion = 1;")
lines.append("\tclasses = {")
lines.append("\t};")
lines.append("\tobjectVersion = 56;")
lines.append("\tobjects = {")
lines.append("")

# PBXFileReference section
lines.append("/* Begin PBXFileReference section */")
app_fid = gen_id("file:QixiangPayMonitor.app")
lines.append(f"\t\t{app_fid} /* QixiangPayMonitor.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = QixiangPayMonitor.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
for f, fid in sorted(file_refs.items()):
    basename = os.path.basename(f)
    if f.endswith(".swift"):
        lines.append(f"\t\t{fid} /* {basename} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {basename}; sourceTree = \"<group>\"; }};")
    elif f.endswith(".plist"):
        lines.append(f"\t\t{fid} /* {basename} */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = {basename}; sourceTree = \"<group>\"; }};")
    elif f.endswith(".xcassets"):
        lines.append(f"\t\t{fid} /* {basename} */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = {basename}; sourceTree = \"<group>\"; }};")
lines.append("/* End PBXFileReference section */")
lines.append("")

# PBXBuildFile section - Swift sources + asset catalogs (Resources)
lines.append("/* Begin PBXBuildFile section */")
for f, bid in sorted(build_files.items()):
    fid = file_refs[f]
    basename = os.path.basename(f)
    phase = "Resources" if f.endswith(".xcassets") else "Sources"
    lines.append(f"\t\t{bid} /* {basename} in {phase} */ = {{isa = PBXBuildFile; fileRef = {fid} /* {basename} */; }};")
lines.append("/* End PBXBuildFile section */")
lines.append("")

# PBXFrameworksBuildPhase section
fw_bid = gen_id("fw:phase")
lines.append("/* Begin PBXFrameworksBuildPhase section */")
lines.append(f"\t\t{fw_bid} /* Frameworks */ = {{")
lines.append("\t\t\tisa = PBXFrameworksBuildPhase;")
lines.append("\t\t\tbuildActionMask = 2147483647;")
lines.append("\t\t\tfiles = (")
lines.append("\t\t\t);")
lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
lines.append("\t\t};")
lines.append("/* End PBXFrameworksBuildPhase section */")
lines.append("")

# PBXGroup section
lines.append("/* Begin PBXGroup section */")
lines.append(f"\t\t{root_gid} = {{")
lines.append("\t\t\tisa = PBXGroup;")
lines.append("\t\t\tchildren = (")

def render_child(child):
    fid_to_name = {v: os.path.basename(k) for k, v in file_refs.items()}
    gid_to_name = {g: k.split("/")[-1] for k, (g, _) in groups.items()}
    if child in fid_to_name:
        return f"\t\t\t\t{child} /* {fid_to_name[child]} */,"
    return f"\t\t\t\t{child} /* {gid_to_name[child]} */,"

for child in groups[""][1]:
    lines.append(render_child(child))
lines.append(f"\t\t\t\t{app_fid} /* QixiangPayMonitor.app */,")
lines.append("\t\t\t);")
lines.append("\t\t\tsourceTree = \"<group>\";")
lines.append("\t\t};")

for key, (gid, children) in sorted(groups.items()):
    if not key:
        continue
    dirname = key.split("/")[-1]
    lines.append(f"\t\t{gid} /* {dirname} */ = {{")
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    for child in children:
        lines.append(render_child(child))
    lines.append("\t\t\t);")
    lines.append(f"\t\t\tpath = {dirname};")
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")
lines.append("/* End PBXGroup section */")
lines.append("")

# PBXNativeTarget section
target_id = gen_id("target:QixiangPayMonitor")
src_phase_id = gen_id("src:phase")
res_phase_id = gen_id("res:phase")
lines.append("/* Begin PBXNativeTarget section */")
lines.append(f"\t\t{target_id} /* QixiangPayMonitor */ = {{")
lines.append("\t\t\tisa = PBXNativeTarget;")
lines.append(f"\t\t\tbuildConfigurationList = {gen_id('bcl:target')} /* Build configuration list for PBXNativeTarget \"QixiangPayMonitor\" */;")
lines.append("\t\t\tbuildPhases = (")
lines.append(f"\t\t\t\t{src_phase_id} /* Sources */,")
lines.append(f"\t\t\t\t{fw_bid} /* Frameworks */,")
lines.append(f"\t\t\t\t{res_phase_id} /* Resources */,")
lines.append("\t\t\t);")
lines.append("\t\t\tbuildRules = (")
lines.append("\t\t\t);")
lines.append("\t\t\tdependencies = (")
lines.append("\t\t\t);")
lines.append("\t\t\tname = QixiangPayMonitor;")
lines.append("\t\t\tproductName = QixiangPayMonitor;")
lines.append(f"\t\t\tproductReference = {app_fid} /* QixiangPayMonitor.app */;")
lines.append("\t\t\tproductType = \"com.apple.product-type.application\";")
lines.append("\t\t};")
lines.append("/* End PBXNativeTarget section */")
lines.append("")

# PBXProject section
proj_id = gen_id("proj:QixiangPayMonitor")
lines.append("/* Begin PBXProject section */")
lines.append(f"\t\t{proj_id} /* Project object */ = {{")
lines.append("\t\t\tisa = PBXProject;")
lines.append("\t\t\tattributes = {")
lines.append("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
lines.append("\t\t\t\tLastSwiftUpdateCheck = 1500;")
lines.append("\t\t\t\tLastUpgradeCheck = 1500;")
lines.append("\t\t\t\tTargetAttributes = {")
lines.append(f"\t\t\t\t\t{target_id} = {{")
lines.append("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
lines.append("\t\t\t\t\t};")
lines.append("\t\t\t\t};")
lines.append("\t\t\t};")
lines.append(f"\t\t\tbuildConfigurationList = {gen_id('bcl:project')} /* Build configuration list for PBXProject \"QixiangPayMonitor\" */;")
lines.append("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
lines.append("\t\t\tdevelopmentRegion = en;")
lines.append("\t\t\thasScannedForEncodings = 0;")
lines.append("\t\t\tknownRegions = (")
lines.append("\t\t\t\ten,")
lines.append("\t\t\t\tBase,")
lines.append("\t\t\t);")
lines.append(f"\t\t\tmainGroup = {root_gid};")
lines.append(f"\t\t\tproductRefGroup = {root_gid};")
lines.append("\t\t\tprojectDirPath = \"\";")
lines.append("\t\t\tprojectRoot = \"\";")
lines.append("\t\t\ttargets = (")
lines.append(f"\t\t\t\t{target_id} /* QixiangPayMonitor */,")
lines.append("\t\t\t);")
lines.append("\t\t};")
lines.append("/* End PBXProject section */")
lines.append("")

# PBXResourcesBuildPhase section (asset catalogs; Info.plist handled by INFOPLIST_FILE)
lines.append("/* Begin PBXResourcesBuildPhase section */")
lines.append(f"\t\t{res_phase_id} /* Resources */ = {{")
lines.append("\t\t\tisa = PBXResourcesBuildPhase;")
lines.append("\t\t\tbuildActionMask = 2147483647;")
lines.append("\t\t\tfiles = (")
for f, bid in sorted(build_files.items()):
    if f.endswith(".xcassets"):
        lines.append(f"\t\t\t\t{bid} /* {os.path.basename(f)} in Resources */,")
lines.append("\t\t\t);")
lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
lines.append("\t\t};")
lines.append("/* End PBXResourcesBuildPhase section */")
lines.append("")

# PBXSourcesBuildPhase section - only Swift files
lines.append("/* Begin PBXSourcesBuildPhase section */")
lines.append(f"\t\t{src_phase_id} /* Sources */ = {{")
lines.append("\t\t\tisa = PBXSourcesBuildPhase;")
lines.append("\t\t\tbuildActionMask = 2147483647;")
lines.append("\t\t\tfiles = (")
for sf, bid in sorted(build_files.items()):
    if sf.endswith(".swift"):
        lines.append(f"\t\t\t\t{bid} /* {os.path.basename(sf)} in Sources */,")
lines.append("\t\t\t);")
lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
lines.append("\t\t};")
lines.append("/* End PBXSourcesBuildPhase section */")
lines.append("")

# XCBuildConfiguration sections
def build_config(config_id, name, is_target, is_debug):
    lines.append(f"\t\t{config_id} /* {name} */ = {{")
    lines.append("\t\t\tisa = XCBuildConfiguration;")
    lines.append("\t\t\tbuildSettings = {")
    if not is_target:
        lines.append("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
        lines.append("\t\t\t\tCLANG_ANALYZER_NONNULL = YES;")
        lines.append("\t\t\t\tCLANG_ENABLE_MODULES = YES;")
        lines.append("\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;")
        lines.append("\t\t\t\tCOPY_PHASE_STRIP = NO;")
        lines.append("\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;")
        lines.append("\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu11;")
        lines.append("\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;")
        lines.append("\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.0;")
        lines.append("\t\t\t\tMTL_FAST_MATH = YES;")
        lines.append("\t\t\t\tSDKROOT = iphoneos;")
        lines.append("\t\t\t\tSWIFT_VERSION = 5.0;")
        if is_debug:
            lines.append("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
            lines.append("\t\t\t\tENABLE_TESTABILITY = YES;")
            lines.append("\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;")
            lines.append("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;")
            lines.append("\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (\"DEBUG=1\", \"$(inherited)\", );")
            lines.append("\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;")
            lines.append("\t\t\t\tONLY_ACTIVE_ARCH = YES;")
            lines.append("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;")
            lines.append("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
        else:
            lines.append("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";")
            lines.append("\t\t\t\tENABLE_NS_ASSERTIONS = NO;")
            lines.append("\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;")
            lines.append("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
            lines.append("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-O\";")
    else:
        lines.append("\t\t\t\tCODE_SIGN_STYLE = Manual;")
        lines.append("\t\t\t\tCURRENT_PROJECT_VERSION = 1;")
        lines.append("\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = NO;")
        lines.append("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;")
        lines.append("\t\t\t\tINFOPLIST_FILE = QixiangPayMonitor/Info.plist;")
        lines.append("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\"$(inherited)\", \"@executable_path/Frameworks\", );")
        lines.append("\t\t\t\tMARKETING_VERSION = 1.0;")
        lines.append("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.doushujun.paymon;")
        lines.append("\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;")
        lines.append("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
        lines.append("\t\t\t\tSWIFT_VERSION = 5.0;")
        lines.append("\t\t\t\tSWIFT_STRICT_CONCURRENCY = minimal;")
        lines.append("\t\t\t\tTARGETED_DEVICE_FAMILY = \"1\";")
    lines.append("\t\t\t};")
    lines.append(f"\t\t\tname = {name};")
    lines.append("\t\t};")

# Project-level configs
build_config(gen_id("pcfg:debug"), "Debug", False, True)
build_config(gen_id("pcfg:release"), "Release", False, False)

# Target-level configs
build_config(gen_id("tcfg:debug"), "Debug", True, True)
build_config(gen_id("tcfg:release"), "Release", True, False)
lines.append("")

# XCConfigurationList sections
lines.append("/* Begin XCConfigurationList section */")
bcl_target = gen_id("bcl:target")
bcl_project = gen_id("bcl:project")
lines.append(f"\t\t{bcl_target} /* Build configuration list for PBXNativeTarget \"QixiangPayMonitor\" */ = {{")
lines.append("\t\t\tisa = XCConfigurationList;")
lines.append("\t\t\tbuildConfigurations = (")
lines.append(f"\t\t\t\t{gen_id('tcfg:debug')} /* Debug */,")
lines.append(f"\t\t\t\t{gen_id('tcfg:release')} /* Release */,")
lines.append("\t\t\t);")
lines.append("\t\t\tdefaultConfigurationIsVisible = 0;")
lines.append("\t\t\tdefaultConfigurationName = Release;")
lines.append("\t\t};")
lines.append(f"\t\t{bcl_project} /* Build configuration list for PBXProject \"QixiangPayMonitor\" */ = {{")
lines.append("\t\t\tisa = XCConfigurationList;")
lines.append("\t\t\tbuildConfigurations = (")
lines.append(f"\t\t\t\t{gen_id('pcfg:debug')} /* Debug */,")
lines.append(f"\t\t\t\t{gen_id('pcfg:release')} /* Release */,")
lines.append("\t\t\t);")
lines.append("\t\t\tdefaultConfigurationIsVisible = 0;")
lines.append("\t\t\tdefaultConfigurationName = Release;")
lines.append("\t\t};")
lines.append("/* End XCConfigurationList section */")
lines.append("")

lines.append("\t};")
lines.append(f"\trootObject = {proj_id} /* Project object */;")
lines.append("}")

# Write to file
xcodeproj_dir = os.path.join(BASE_DIR, "QixiangPayMonitor.xcodeproj")
os.makedirs(xcodeproj_dir, exist_ok=True)
out_path = os.path.join(xcodeproj_dir, "project.pbxproj")
with open(out_path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
print(f"\nGenerated: {out_path}")
print(f"Total Swift files: {len(swift_files)}")
print(f"Total plist files: {len(plist_files)}")
