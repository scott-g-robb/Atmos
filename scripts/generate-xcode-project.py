#!/usr/bin/env python3
"""Keep the native WeatherKit-capable target in sync with the Swift package."""
import hashlib, plistlib
from pathlib import Path
root=Path(__file__).resolve().parent.parent
objects={}
def ident(name):return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(object_key,isa,**fields):
 key=ident(object_key);objects[key]={'isa':isa,**fields};return key
files=[];builds=[]
source_files=sorted((root/'Sources/Atmos').rglob('*.swift'))+[root/'Sources/CWeatherCore/WeatherCore.c']
for file in source_files:
 path=str(file.relative_to(root))
 ref=add(path,'PBXFileReference',lastKnownFileType='sourcecode.c.c' if file.suffix=='.c' else 'sourcecode.swift',path=path,sourceTree='SOURCE_ROOT')
 files.append(ref);builds.append(add(path+' build','PBXBuildFile',fileRef=ref))
product=add('product','PBXFileReference',explicitFileType='wrapper.application',path='Atmos.app',sourceTree='BUILT_PRODUCTS_DIR')
products=add('products','PBXGroup',children=[product],name='Products',sourceTree='<group>')
group=add('main','PBXGroup',children=files+[products],sourceTree='<group>')
pre=add('rust','PBXShellScriptBuildPhase',buildActionMask=2147483647,files=[],inputPaths=[],outputPaths=[],runOnlyForDeploymentPostprocessing=0,shellPath='/bin/zsh',shellScript='"$SRCROOT/scripts/build-weather-core.sh"\n',name='Build universal Rust physics',alwaysOutOfDate='1')
sources=add('sources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=builds,runOnlyForDeploymentPostprocessing=0)
assets=add('assets','PBXShellScriptBuildPhase',buildActionMask=2147483647,files=[],inputPaths=[],outputPaths=[],runOnlyForDeploymentPostprocessing=0,shellPath='/bin/zsh',name='Compile Atmos artwork',alwaysOutOfDate='1',shellScript='''set -e
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$resources"
xcrun actool "$SRCROOT/Resources/AppIcon.icon" --compile "$resources" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$DERIVED_FILE_DIR/icon-info.plist" --output-format human-readable-text
swift "$SRCROOT/scripts/build-icons.swift" "$SRCROOT/Resources/AppIcon.icon/Assets/Weather.png" "$DERIVED_FILE_DIR/AppIcon.iconset"
iconutil -c icns "$DERIVED_FILE_DIR/AppIcon.iconset" -o "$resources/AppIcon.icns"
cp "$SRCROOT/LICENSE" "$resources/LICENSE.txt"
cp "$SRCROOT/NOTICE.md" "$resources/NOTICE.md"
cp "$SRCROOT/Resources/IntroAudio.mp3" "$resources/IntroAudio.mp3"
''')
configs=[];projectconfigs=[]
for name in ['Debug','Release']:
 settings={'PRODUCT_NAME':'Atmos','PRODUCT_BUNDLE_IDENTIFIER':'dev.grobb.Atmos','DEVELOPMENT_TEAM':'8QDD68TVRK','CODE_SIGN_STYLE':'Automatic','CODE_SIGN_ENTITLEMENTS':'Resources/WeatherKit.entitlements','INFOPLIST_FILE':'Resources/Info.plist','GENERATE_INFOPLIST_FILE':'NO','MACOSX_DEPLOYMENT_TARGET':'14.0','SDKROOT':'macosx','SUPPORTED_PLATFORMS':'macosx','SWIFT_VERSION':'5.0','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if name=='Debug' else '-O','SWIFT_COMPILATION_MODE':'wholemodule' if name=='Release' else 'singlefile','ENABLE_HARDENED_RUNTIME':'YES','ENABLE_USER_SCRIPT_SANDBOXING':'NO','OTHER_SWIFT_FLAGS':['$(inherited)','-I','$(SRCROOT)/Sources/CWeatherCore/include'],'HEADER_SEARCH_PATHS':['$(inherited)','$(SRCROOT)/Sources/CWeatherCore/include'],'LIBRARY_SEARCH_PATHS':['$(inherited)','$(SRCROOT)/.build/weather-core'],'OTHER_LDFLAGS':['$(inherited)','-latmos_weather_core'],'LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/../Frameworks'],'COMBINE_HIDPI_IMAGES':'YES'}
 configs.append(add('target '+name,'XCBuildConfiguration',name=name,buildSettings=settings))
 projectconfigs.append(add('project '+name,'XCBuildConfiguration',name=name,buildSettings={'CLANG_ENABLE_MODULES':'YES','MACOSX_DEPLOYMENT_TARGET':'14.0','SDKROOT':'macosx'}))
targetlist=add('targetconfigs','XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
projectlist=add('projectconfigs','XCConfigurationList',buildConfigurations=projectconfigs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
target=add('target','PBXNativeTarget',name='Atmos',productName='Atmos',productReference=product,productType='com.apple.product-type.application',buildConfigurationList=targetlist,buildPhases=[pre,sources,assets],buildRules=[],dependencies=[])
project=add('project','PBXProject',attributes={'LastUpgradeCheck':'2700','TargetAttributes':{target:{'DevelopmentTeam':'8QDD68TVRK','SystemCapabilities':{'com.apple.WeatherKit':{'enabled':1}}}}},buildConfigurationList=projectlist,compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','Base'],mainGroup=group,productRefGroup=products,projectDirPath='',projectRoot='',targets=[target])
folder=root/'Atmos.xcodeproj';folder.mkdir(exist_ok=True)
(folder/'project.pbxproj').write_bytes(plistlib.dumps({'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':project},sort_keys=False))
scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Atmos.app" BlueprintName="Atmos" ReferencedContainer="container:Atmos.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Atmos.app" BlueprintName="Atmos" ReferencedContainer="container:Atmos.xcodeproj"/></BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>'''
(folder/'xcshareddata/xcschemes').mkdir(parents=True,exist_ok=True)
(folder/'xcshareddata/xcschemes/Atmos.xcscheme').write_text(scheme)
print('Updated native WeatherKit-enabled Atmos.xcodeproj')
