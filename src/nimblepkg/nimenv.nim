import std/[strscans, os, strutils, strformat, options]
import version, cli, common, options

when defined(windows):
  const
    BatchFile = """
  @echo off
  set PATH="$1";%PATH%
  """
else:
  const
    ShellFile = "export PATH=$1:$$PATH\n"

const ActivationFile = 
  when defined(windows): "activate.bat" else: "activate.sh"

proc infoAboutActivation(nimDest, nimVersion: string) =
  when defined(windows):
    display("Info", nimDest & "installed; activate with 'nim-" & nimVersion & "activate.bat'")
  else:
    display("Info", nimDest & "installed; activate with 'source nim-" & nimVersion & "activate.sh'")

proc compileNim*(options: Options, nimDest: string, v: VersionRange) =
  # 1. If nim is already properly installed at nimDest, skip.
  let nimBinPath = nimDest / "bin" / "nim".addFileExt(ExeExt)
  let nimCompVersion = getNimVersionFromBin(nimBinPath)
  if nimCompVersion.isSome() and nimCompVersion.get.withinRange(v):
    return

  # 2. If the system nim satisfies the version requirement, copy it to nimDest
  # instead of bootstrapping from C sources.  Bootstrapping fails on Windows
  # because Koch cannot replace bin/nim.exe while it is in use (OS file lock).
  let systemNimExe = findExe("nim")
  if systemNimExe != "":
    let systemNimVersion = getNimVersionFromBin(systemNimExe)
    if systemNimVersion.isSome() and systemNimVersion.get.withinRange(v):
      display("Info:", "system Nim $1 satisfies $2; reusing it instead of bootstrapping" %
              [$systemNimVersion.get, $v], priority = HighPriority)
      createDir(nimDest / "bin")
      copyFileWithPermissions(systemNimExe, nimBinPath)
      let pathEntry = nimDest / "bin"
      when defined(windows):
        writeFile(nimDest / ActivationFile, BatchFile % pathEntry.replace('/', '\\'))
      else:
        writeFile(nimDest / ActivationFile, ShellFile % pathEntry)
      return

  let keepCsources = true # SAT Solver uses a cache instead of a temp dir for downloads
  template exec(command: string) =
    let cmd = command # eval once
    if os.execShellCmd(cmd) != 0:
      display("Error", "Failed to execute: $1" % cmd, Error, HighPriority)
      return
  let nimVersion = v.getNimVersion()
  let canUseCsources = v.kind != verAny
  let workspace = nimDest.parentDir()
  if dirExists(workspace / nimDest):
    if not fileExists(nimDest / ActivationFile):
      display("Info", &"Directory {nimDest} already exists; remove or rename and try again")
    else:
      infoAboutActivation nimDest, $nimVersion
    return

  var major, minor, patch: int
  if not nimVersion.isSpecial: 
    if not scanf($nimVersion, "$i.$i.$i", major, minor, patch):
      display("Error", "cannot parse version requirement", Error)
      return
  let csourcesVersion =
    #TODO We could test special against the special version-x branch to get the right csources
    if nimVersion.isSpecial or major >= 2 and minor >= 2:
      # devel and 2.2+ need csources_v3
      "csources_v3"
    elif (major == 1 and minor >= 9) or major >= 2:
      # 1.9+ and 2.0/2.1 use csources_v2
      "csources_v2"
    elif major == 0:
      "csources" # has some chance of working
    else:
      "csources_v1"
  cd workspace:
    if not dirExists(csourcesVersion):
      exec "git clone https://github.com/nim-lang/" & csourcesVersion

  var csourcesSucceed = false
  if canUseCsources:
    cd workspace / csourcesVersion:
      when defined(windows):
        let cmd = "build.bat"
        csourcesSucceed = os.execShellCmd(cmd) == 0
      else:
        let makeExe = findExe("make")
        if makeExe.len == 0:
          let cmd = "sh build.sh"
          csourcesSucceed = os.execShellCmd(cmd) == 0
        else:
          let cmd = "make"
          csourcesSucceed = os.execShellCmd(cmd) == 0

  cd nimDest:
    #Sometimes building from csources fails and we cant do much about it. So we fallback to the slow build_all method
    if not csourcesSucceed:
      display("Warning", "Building nim from csources failed. Using `build_all`", Warning, HighPriority)
      let cmd = 
        when defined(windows):  "build_all.bat" 
        else: "sh build_all.sh"
      exec cmd
    let nimExe = "bin" / "nim".addFileExt(ExeExt)
    let nimExe0 = ".." / csourcesVersion / "bin" / "nim".addFileExt(ExeExt)
    if csourcesSucceed:      
      copyFileWithPermissions nimExe0, nimExe
    exec nimExe & " c --noNimblePath --skipUserCfg --skipParentCfg --hints:off koch"
    let kochExe = when defined(windows): "koch.exe" else: "./koch"
    exec kochExe & " boot -d:release --skipUserCfg --skipParentCfg --hints:off"
    exec kochExe & " tools --skipUserCfg --skipParentCfg --hints:off"
    # unless --keep is used delete the csources because it takes up about 2GB and
    # is not necessary afterwards:
    if not keepCsources:
      removeDir workspace / csourcesVersion / "c_code"
    let pathEntry = workspace / nimDest / "bin"
    #remove nimble so it doesnt interfer with the current one:
    removeFile "bin" / "nimble".addFileExt(ExeExt)
    when defined(windows):
      writeFile "activate.bat", BatchFile % pathEntry.replace('/', '\\')
    else:
      writeFile "activate.sh", ShellFile % pathEntry
    infoAboutActivation nimDest, $nimVersion


proc useNimFromDir*(options: var Options, realDir: string, v: VersionRange, tryCompiling = false) =
  const binaryName = when defined(windows): "nim.exe" else: "nim"

  let
    nim = realDir / "bin" / binaryName
    fileExists = fileExists(options.nimBin.get(NimBin()).path)

  if not fileExists(nim):
    if tryCompiling and options.prompt("Develop version of nim was found but it is not compiled. Compile it now?"):
      compileNim(options, realDir, v)
    else:
      raise nimbleError("Trying to use nim from $1 " % realDir,
                        "If you are using develop mode nim make sure to compile it.")

  options.nimBin = some makeNimBin(options, nim)
  let separator = when defined(windows): ";" else: ":"

  putEnv("PATH", realDir / "bin" & separator & getEnv("PATH"))
  if fileExists:
    display("Info:", "switching to $1 for compilation" % options.nim, priority = HighPriority)
  else:
    display("Info:", "using $1 for compilation" % options.nim, priority = HighPriority)
