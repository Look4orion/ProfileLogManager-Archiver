param([string]$Run, [switch]$NoUpload)

$script:PLMA_ARCHIVED_MAX = 100000
$script:PLMA_Dir = $PSScriptRoot
$script:PLMA_Script = $PSCommandPath

function ConvertTo-PLMACleanLine([string]$s) {
  if ($null -eq $s) { return '' }
  return $s.Replace([string][char]0xFEFF, '').Trim()
}

function ConvertFrom-PLMAIndexLine([string]$Line, [string]$LogFolder) {
  $clean = ConvertTo-PLMACleanLine $Line
  $parts = $clean.Split('/')
  foreach ($p in $parts) {
    if ($p -eq '' -or $p -eq '.' -or $p -eq '..') { return $null }
    if ($p.IndexOfAny([char[]]@('\', ':', '*', '?', '"', '<', '>', '|')) -ge 0) { return $null }
    if ($p.EndsWith('.') -or $p.EndsWith(' ')) { return $null }
    foreach ($ch in $p.ToCharArray()) { if ([int]$ch -lt 32) { return $null } }
    $stem = $p.Split('.')[0].TrimEnd(' ')
    if ($stem -match '^(?i)(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9]|CONIN\$|CONOUT\$)$') { return $null }
  }
  $n = $parts.Count
  if ($n -lt 3 -or $n -gt 5) { return $null }
  $name = $parts[$n - 1]
  $day = $parts[$n - 2]
  if ($parts[0] -ceq $LogFolder) {
    if ($n -eq 5) { return $null }
    if ($n -eq 3) { $source = 'Server' } else { $source = $parts[2]; $day = $parts[1] }
  } else {
    $source = $parts[0]
  }
  if ($day -notmatch '^\d{4}-\d{2}-\d{2}$') { return $null }
  $dt = [datetime]::MinValue
  if (-not [datetime]::TryParseExact($day, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$dt)) { return $null }
  return [pscustomobject]@{
    Line      = $clean
    Day       = $day
    Source    = $source
    Name      = $name
    ZipPath   = "$source/$name"
    ServerDir = $clean.Substring(0, $clean.Length - $name.Length - 1)
  }
}

function Get-PLMAPlan([string[]]$IndexLines, [string]$LogFolder) {
  $items = New-Object System.Collections.ArrayList
  $rejected = New-Object System.Collections.ArrayList
  $collisions = New-Object System.Collections.ArrayList
  $seenLines = @{}
  $byKey = @{}
  foreach ($raw in @($IndexLines)) {
    $clean = ConvertTo-PLMACleanLine $raw
    if ($clean -eq '') { continue }
    if ($seenLines.ContainsKey($clean)) { continue }
    $seenLines[$clean] = $true
    $item = ConvertFrom-PLMAIndexLine $clean $LogFolder
    if ($null -eq $item) { [void]$rejected.Add([string]$raw); continue }
    $key = $item.Day + '|' + $item.ZipPath
    if ($byKey.ContainsKey($key)) {
      [void]$collisions.Add("Same zip path '$($item.ZipPath)' on $($item.Day) from two lines: '$($byKey[$key].Line)' and '$($item.Line)'")
      continue
    }
    $byKey[$key] = $item
    [void]$items.Add($item)
  }
  return @{
    Items      = $items.ToArray()
    Rejected   = [string[]]$rejected.ToArray()
    Collisions = [string[]]$collisions.ToArray()
  }
}

function Merge-PLMAArchivedLines([string[]]$Existing, [string[]]$New) {
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $out = New-Object 'System.Collections.Generic.List[string]'
  foreach ($l in (@($Existing) + @($New))) {
    $c = ConvertTo-PLMACleanLine $l
    if ($c -eq '') { continue }
    if ($seen.Add($c)) { $out.Add($c) }
  }
  return , $out.ToArray()
}

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

function Get-PLMAFileHashHex($Source) {
  $sha = [Security.Cryptography.SHA256]::Create()
  $stream = $null
  $own = $false
  try {
    if ($Source -is [IO.Stream]) {
      $stream = $Source
    } else {
      $stream = [IO.File]::OpenRead([string]$Source)
      $own = $true
    }
    return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
  } finally {
    if ($own -and $null -ne $stream) { $stream.Dispose() }
    $sha.Dispose()
  }
}

function Get-PLMAZipEntries([string]$ZipFile) {
  $result = New-Object 'System.Collections.Generic.Dictionary[string,long]' ([StringComparer]::Ordinal)
  if (-not (Test-Path -LiteralPath $ZipFile)) { return $result }
  $zip = $null
  try {
    try {
      $zip = [IO.Compression.ZipFile]::Open($ZipFile, 'Read')
    } catch {
      throw "$ZipFile is not a readable zip"
    }
    foreach ($e in $zip.Entries) { $result[$e.FullName] = $e.Length }
  } finally {
    if ($null -ne $zip) { $zip.Dispose() }
  }
  return $result
}

function Copy-PLMAStream($In, $Entry) {
  $out = $null
  try {
    $out = $Entry.Open()
    $In.CopyTo($out)
  } finally {
    $In.Dispose()
    if ($null -ne $out) { $out.Dispose() }
  }
}

function Add-PLMAToDayZip([string]$ZipFile, [object[]]$Files) {
  $newFile = "$ZipFile.new"
  if (Test-Path -LiteralPath $newFile) { Remove-Item -LiteralPath $newFile -Force }
  $existing = Get-PLMAZipEntries $ZipFile
  $zipExists = Test-Path -LiteralPath $ZipFile
  $todo = New-Object System.Collections.ArrayList
  $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($f in @($Files)) {
    $name = [string]$f.ZipPath
    if ($existing.ContainsKey($name) -or -not $names.Add($name)) { continue }
    [void]$todo.Add($f)
  }
  if ($todo.Count -eq 0) { return , ([string[]]@()) }
  $copied = 0
  $swapped = $false
  try {
    $fs = $null
    $zip = $null
    $old = $null
    try {
      $fs = New-Object IO.FileStream($newFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
      $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
      if ($zipExists) {
        $old = [IO.Compression.ZipFile]::Open($ZipFile, 'Read')
        foreach ($oe in $old.Entries) {
          $entry = $zip.CreateEntry($oe.FullName, [IO.Compression.CompressionLevel]::Optimal)
          $entry.LastWriteTime = $oe.LastWriteTime
          Copy-PLMAStream $oe.Open() $entry
          $copied++
        }
      }
      foreach ($f in $todo) {
        $entry = $zip.CreateEntry([string]$f.ZipPath, [IO.Compression.CompressionLevel]::Optimal)
        Copy-PLMAStream ([IO.File]::OpenRead([string]$f.StagedPath)) $entry
      }
    } finally {
      try {
        if ($null -ne $zip) { $zip.Dispose() }
      } finally {
        if ($null -ne $fs) { $fs.Dispose() }
        if ($null -ne $old) { $old.Dispose() }
      }
    }
    $zip = $null
    try {
      $zip = [IO.Compression.ZipFile]::Open($newFile, 'Read')
      if ($zip.Entries.Count -ne $copied + $todo.Count) { throw "Check failed: $newFile holds $($zip.Entries.Count) entries, expected $($copied + $todo.Count)" }
      $got = New-Object 'System.Collections.Generic.Dictionary[string,long]' ([StringComparer]::Ordinal)
      foreach ($e in $zip.Entries) { $got[$e.FullName] = $e.Length }
      foreach ($k in $existing.Keys) {
        if (-not $got.ContainsKey($k) -or $got[$k] -ne $existing[$k]) { throw "Check failed: old entry $k not carried into $newFile" }
      }
      foreach ($f in $todo) {
        $name = [string]$f.ZipPath
        $entry = $zip.GetEntry($name)
        if ($null -eq $entry) { throw "Check failed: $name missing from $newFile" }
        $es = $entry.Open()
        try { $zipHash = Get-PLMAFileHashHex $es } finally { $es.Dispose() }
        $srcHash = Get-PLMAFileHashHex ([string]$f.StagedPath)
        if ($zipHash -ne $srcHash) { throw "Check failed: hash of $name in $newFile does not match the staged copy" }
      }
    } finally {
      if ($null -ne $zip) { $zip.Dispose() }
    }
    if ($zipExists) {
      [IO.File]::Replace($newFile, $ZipFile, [NullString]::Value)
    } else {
      [IO.File]::Move($newFile, $ZipFile)
    }
    $swapped = $true
  } finally {
    if (-not $swapped -and (Test-Path -LiteralPath $newFile)) { Remove-Item -LiteralPath $newFile -Force }
  }
  return , ([string[]]@($todo | ForEach-Object { [string]$_.ZipPath }))
}

function Find-PLMAWinSCP() {
  $cands = New-Object System.Collections.ArrayList
  if ($env:WinSCP_PATH) { [void]$cands.Add([string]$env:WinSCP_PATH) }
  foreach ($hive in @('HKLM', 'HKCU')) {
    foreach ($view in @('', '\WOW6432Node')) {
      try {
        $key = "${hive}:\SOFTWARE${view}\Microsoft\Windows\CurrentVersion\Uninstall\winscp3_is1"
        $loc = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).InstallLocation
        if ($loc) { [void]$cands.Add([string]$loc) }
      } catch { $null = $_ }
    }
  }
  if (${env:ProgramFiles(x86)}) { [void]$cands.Add((Join-Path ${env:ProgramFiles(x86)} 'WinSCP')) }
  if ($env:ProgramFiles) { [void]$cands.Add((Join-Path $env:ProgramFiles 'WinSCP')) }
  foreach ($c in $cands) {
    if (Test-Path -LiteralPath (Join-Path $c 'WinSCPnet.dll') -PathType Leaf) { return $c }
  }
  return $null
}

function New-PLMAFinalError([string]$Message) {
  $e = New-Object System.Exception($Message)
  $e.Data['PLMAFinal'] = $true
  return $e
}

function Import-PLMAWinSCP() {
  if ($script:PLMA_WinSCPLoaded) { return }
  $dir = Find-PLMAWinSCP
  if ($null -eq $dir) { throw (New-PLMAFinalError 'WinSCP not found - install it from winscp.net') }
  Add-Type -Path (Join-Path $dir 'WinSCPnet.dll')
  $script:PLMA_WinSCPLoaded = $true
}

function Get-PLMAHostKey([string]$HostName, [int]$Port) {
  Import-PLMAWinSCP
  $opts = New-Object WinSCP.SessionOptions
  $opts.Protocol = [WinSCP.Protocol]::Sftp
  $opts.HostName = $HostName
  $opts.PortNumber = $Port
  $session = New-Object WinSCP.Session
  try {
    return [string]$session.ScanFingerprint($opts, 'SHA-256')
  } finally { $session.Dispose() }
}

function Test-PLMAMessageHas([object]$Ex, [string]$Pattern) {
  while ($null -ne $Ex) {
    if ($Ex.Message -match $Pattern) { return $true }
    $Ex = $Ex.InnerException
  }
  return $false
}

function Open-PLMASource([hashtable]$Server, [string]$WorkDir) {
  if ($Server.Mode -eq 'Local') {
    return [pscustomobject]@{ Kind = 'Local'; Root = [string]$Server.ProfilePath; Session = $null; Work = $null }
  }
  if ($Server.Mode -ne 'Remote') { throw "Mode '$($Server.Mode)' is not supported" }
  Import-PLMAWinSCP
  if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('PLMA_' + [guid]::NewGuid().ToString('N')) }
  $opts = New-Object WinSCP.SessionOptions
  $opts.Protocol = [WinSCP.Protocol]::Sftp
  $opts.HostName = [string]$Server.HostName
  $opts.PortNumber = [int]$Server.Port
  $opts.UserName = [string]$Server.UserName
  $opts.SecurePassword = ConvertTo-SecureString ([string]$Server.Password)
  $opts.SshHostKeyFingerprint = [string]$Server.HostKey
  New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
  $session = New-Object WinSCP.Session
  try {
    $session.Open($opts)
  } catch {
    $ex = $_.Exception
    $session.Dispose()
    if (Test-PLMAMessageHas $ex 'host key') {
      throw (New-PLMAFinalError "the server's host key has changed, nothing copied or written. If you moved host on purpose, run setup again.")
    }
    throw
  }
  return [pscustomobject]@{ Kind = 'Remote'; Root = [string]$Server.ProfilePath; Session = $session; Work = $WorkDir }
}

function Close-PLMASource($Src) {
  if ($null -eq $Src) { return }
  if ($null -ne $Src.Session) { $Src.Session.Dispose() }
  if ($Src.Kind -eq 'Remote' -and $Src.Work -and (Test-Path -LiteralPath $Src.Work)) {
    Remove-Item -LiteralPath $Src.Work -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Get-PLMARemotePath($Src, [string]$Rel) {
  return ($Src.Root.TrimEnd('/') + '/' + $Rel)
}

function New-PLMATransferOptions() {
  $to = New-Object WinSCP.TransferOptions
  $to.TransferMode = [WinSCP.TransferMode]::Binary
  $to.ResumeSupport.State = [WinSCP.TransferResumeSupportState]::Off
  return $to
}

function Get-PLMALocalPath($Src, [string]$Rel) {
  return (Join-Path $Src.Root ($Rel -replace '/', '\'))
}

function Read-PLMAServerText($Src, [string]$Rel) {
  if ($Src.Kind -eq 'Remote') {
    $remote = Get-PLMARemotePath $Src $Rel
    if (-not $Src.Session.FileExists($remote)) { return $null }
    $got = Join-Path $Src.Work ([IO.Path]::GetFileName($Rel))
    if (Test-Path -LiteralPath $got) { Remove-Item -LiteralPath $got -Force }
    $Src.Session.GetFileToDirectory($remote, $Src.Work, $false, (New-PLMATransferOptions)) | Out-Null
    try {
      return [IO.File]::ReadAllText($got, (New-Object Text.UTF8Encoding $false))
    } finally { Remove-Item -LiteralPath $got -Force -ErrorAction SilentlyContinue }
  }
  $path = Get-PLMALocalPath $Src $Rel
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try {
    $sr = New-Object IO.StreamReader($fs, (New-Object Text.UTF8Encoding $false), $true)
    return $sr.ReadToEnd()
  } finally { $fs.Dispose() }
}

function Get-PLMAServerSizes($Src, [string]$RelDir) {
  $sizes = New-Object 'System.Collections.Generic.Dictionary[string,long]' ([StringComparer]::Ordinal)
  if ($Src.Kind -eq 'Remote') {
    $remote = Get-PLMARemotePath $Src $RelDir
    if (-not $Src.Session.FileExists($remote)) { return $sizes }
    foreach ($f in $Src.Session.ListDirectory($remote).Files) {
      if (-not $f.IsDirectory) { $sizes[$f.Name] = [int64]$f.Length }
    }
    return $sizes
  }
  $path = Get-PLMALocalPath $Src $RelDir
  if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $sizes }
  foreach ($f in (Get-ChildItem -LiteralPath $path -File)) { $sizes[$f.Name] = [int64]$f.Length }
  return $sizes
}

function Save-PLMAServerFile($Src, [string]$Rel, [string]$LocalPath) {
  $dir = Split-Path -Parent $LocalPath
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  if ($Src.Kind -eq 'Remote') {
    $remote = Get-PLMARemotePath $Src $Rel
    if (-not $Src.Session.FileExists($remote)) { throw (New-Object IO.FileNotFoundException("not on the server: $remote")) }
    try {
      $Src.Session.GetFileToDirectory($remote, $dir, $false, (New-PLMATransferOptions)) | Out-Null
    } catch {
      $orig = $_
      $gone = $false
      try { $gone = -not $Src.Session.FileExists($remote) } catch { $null = $_ }
      if ($gone) { throw (New-Object IO.FileNotFoundException("gone from the server: $remote")) }
      throw $orig
    }
    $got = Join-Path $dir ([IO.Path]::GetFileName($Rel))
    if ($got -ne $LocalPath) { Move-Item -LiteralPath $got -Destination $LocalPath -Force }
    return
  }
  $from = Get-PLMALocalPath $Src $Rel
  $in = $null
  $out = $null
  try {
    $in = New-Object IO.FileStream($from, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $out = New-Object IO.FileStream($LocalPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $in.CopyTo($out)
  } finally {
    if ($null -ne $out) { $out.Dispose() }
    if ($null -ne $in) { $in.Dispose() }
  }
}

function Publish-PLMAArchived($Src, [string[]]$Lines) {
  $content = ((@($Lines) -join "`r`n") + "`r`n")
  if ($Src.Kind -eq 'Remote') {
    $localTmp = Join-Path $Src.Work 'Archived.tmp'
    [IO.File]::WriteAllText($localTmp, $content, (New-Object Text.UTF8Encoding $false))
    $s = $Src.Session
    $remoteDir = Get-PLMARemotePath $Src 'ProfileLogManager'
    $remoteTmp = "$remoteDir/Archived.tmp"
    $remoteTxt = "$remoteDir/Archived.txt"
    $s.PutFileToDirectory($localTmp, $remoteDir, $false, (New-PLMATransferOptions)) | Out-Null
    try {
      $s.MoveFile($remoteTmp, $remoteTxt) | Out-Null
    } catch {
      if (-not $s.FileExists($remoteTxt)) { throw }
      $s.RemoveFile($remoteTxt) | Out-Null
      $s.MoveFile($remoteTmp, $remoteTxt) | Out-Null
    }
    return
  }
  $dir = Get-PLMALocalPath $Src 'ProfileLogManager'
  $tmp = Join-Path $dir 'Archived.tmp'
  $txt = Join-Path $dir 'Archived.txt'
  [IO.File]::WriteAllText($tmp, $content, (New-Object Text.UTF8Encoding $false))
  if (Test-Path -LiteralPath $txt) {
    [IO.File]::Replace($tmp, $txt, [NullString]::Value)
  } else {
    [IO.File]::Move($tmp, $txt)
  }
}

function Write-PLMARunLog([string]$BaseDir, [string]$Name, [string[]]$Lines) {
  $dir = Join-Path (Join-Path $BaseDir 'logs') $Name
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $stamp = (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')
  $file = Join-Path $dir "PLMArchiver_$stamp.log"
  $i = 1
  while (Test-Path -LiteralPath $file) {
    $i++
    $file = Join-Path $dir ("PLMArchiver_{0}_{1:00}.log" -f $stamp, $i)
  }
  [IO.File]::WriteAllText($file, ((@($Lines) -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $false))
  $names = [string[]]@(Get-ChildItem -LiteralPath $dir -Filter 'PLMArchiver_*.log' -File | ForEach-Object { $_.Name })
  [Array]::Sort($names, [StringComparer]::Ordinal)
  for ($k = 0; $k -lt $names.Count - 20; $k++) {
    Remove-Item -LiteralPath (Join-Path $dir $names[$k]) -Force
  }
  return $file
}

function Test-PLMALockLive([string]$Text) {
  $parts = ([string]$Text).Trim().Split(' ')
  if ($parts.Count -ne 2) { return $false }
  $id = 0
  $ticks = [long]0
  if (-not [int]::TryParse($parts[0], [ref]$id) -or $id -le 0) { return $false }
  if (-not [long]::TryParse($parts[1], [ref]$ticks)) { return $false }
  try {
    $p = Get-Process -Id $id -ErrorAction Stop
    return ($p.StartTime.ToUniversalTime().Ticks -eq $ticks)
  } catch { return $false }
}

function Enter-PLMALock([string]$LockFile) {
  $mine = [Text.Encoding]::ASCII.GetBytes("$PID " + (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks)
  for ($try = 0; $try -lt 2; $try++) {
    $fs = $null
    try {
      $fs = New-Object IO.FileStream($LockFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
      try {
        $fs = New-Object IO.FileStream($LockFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
      } catch [IO.FileNotFoundException] {
        continue
      } catch {
        return $null
      }
      $text = ''
      try {
        $buf = New-Object byte[] 256
        $n = $fs.Read($buf, 0, $buf.Length)
        $text = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
      } catch { $text = '' }
      if (Test-PLMALockLive $text) { $fs.Dispose(); return $null }
      $fs.SetLength(0)
    }
    try {
      $fs.Write($mine, 0, $mine.Length)
      $fs.Flush()
    } catch {
      $fs.Dispose()
      throw
    }
    return $fs
  }
  return $null
}

function Test-PLMAFullPath([string]$Path) {
  return ($Path -match '^[A-Za-z]:[\\/]' -or $Path -match '^[\\/]{2}[^\\/]')
}

function Close-PLMARun([hashtable]$St, [string]$Result, [int]$Code) {
  $lines = @($Result) + @($St.Fails) + @($St.Warns)
  try { [void](Write-PLMARunLog $St.BaseDir $St.Name ([string[]]$lines)) } catch { Write-Host "could not write the run log: $($_.Exception.Message)" }
  Write-Host $Result
  return $Code
}

function Invoke-PLMARun([hashtable]$Server, [switch]$NoUpload, [string]$BaseDir) {
  $name = [string]$Server.Name
  $st = @{ BaseDir = $BaseDir; Name = $name; Fails = (New-Object System.Collections.ArrayList); Warns = (New-Object System.Collections.ArrayList) }
  $workRoot = Join-Path $BaseDir 'work'
  $lockFile = Join-Path $workRoot "$name.lock"
  $lock = $null
  $src = $null
  try {
    if (-not (Test-PLMAFullPath ([string]$Server.BackupFolder))) {
      return (Close-PLMARun $st "FAILED: the backup folder '$($Server.BackupFolder)' is not a full path - run setup again" 2)
    }
    if ($Server.Mode -eq 'Local' -and -not (Test-PLMAFullPath ([string]$Server.ProfilePath))) {
      return (Close-PLMARun $st "FAILED: the profile folder '$($Server.ProfilePath)' is not a full path - run setup again" 2)
    }
    if (-not (Test-Path -LiteralPath $workRoot)) { New-Item -ItemType Directory -Force -Path $workRoot | Out-Null }
    $lock = Enter-PLMALock $lockFile
    if ($null -eq $lock) {
      return (Close-PLMARun $st "FAILED: another run of $name is going" 2)
    }
    try {
      $src = Open-PLMASource $Server (Join-Path $workRoot "$name.remote")
    } catch {
      if ($_.Exception.Data['PLMAFinal']) { return (Close-PLMARun $st "FAILED: $($_.Exception.Message)" 2) }
      return (Close-PLMARun $st "FAILED: could not open the source: $($_.Exception.Message)" 2)
    }

    $logFolder = 'zz_logs'; $mode = 'Days'; $keepDays = 30
    $badSettings = 'FAILED: could not read ProfileLogManager/Settings.json, nothing copied or written'
    $settingsText = Read-PLMAServerText $src 'ProfileLogManager/Settings.json'
    if ($null -eq $settingsText) { return (Close-PLMARun $st $badSettings 2) }
    try {
      $settings = $settingsText | ConvertFrom-Json
      if ($null -eq $settings) { throw 'empty' }
      if ($null -ne $settings.PLM_LogFolder) { $logFolder = [string]$settings.PLM_LogFolder }
      if ($null -ne $settings.PLM_DeleteMode) { $mode = [string]$settings.PLM_DeleteMode }
      if ($null -ne $settings.PLM_KeepDays) { $keepDays = [double]$settings.PLM_KeepDays }
    } catch {
      return (Close-PLMARun $st $badSettings 2)
    }

    $indexText = Read-PLMAServerText $src 'ProfileLogManager/Index.txt'
    if ($null -eq $indexText) {
      return (Close-PLMARun $st 'FAILED: no ProfileLogManager/Index.txt (has the server restarted with Profile Log Manager?)' 2)
    }
    $plan = Get-PLMAPlan ($indexText -split "`n") $logFolder
    if ($plan.Collisions.Count -gt 0) {
      foreach ($c in $plan.Collisions) { [void]$st.Fails.Add($c) }
      return (Close-PLMARun $st 'FAILED: two logs would share a zip path, nothing copied or written' 2)
    }
    foreach ($r in $plan.Rejected) { [void]$st.Warns.Add("skipped unsafe index line: $(ConvertTo-PLMACleanLine $r)") }

    if ($mode -ceq 'Days') {
      [void]$st.Warns.Add('Days mode: the mod deletes by age, the archiver backs up but cannot keep anything from deletion')
      if ($keepDays -gt 0 -and ($keepDays * 24) -lt [double]$Server.ScheduleHours) {
        [void]$st.Warns.Add("PLM_KeepDays ($keepDays days) is shorter than the schedule ($($Server.ScheduleHours) hours): logs may be deleted before a run reaches them")
      }
    } elseif ($mode -cne 'Archived') {
      [void]$st.Warns.Add("PLM_DeleteMode ""$mode"" deletes nothing; Archived.txt not written")
    }

    $backupDir = Join-Path ([string]$Server.BackupFolder) $name
    $stageRoot = Join-Path $workRoot $name
    $verified = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $newFiles = 0
    $zipsTouched = 0
    $sizeCache = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)

    $days = @($plan.Items | ForEach-Object { $_.Day } | Select-Object -Unique)
    foreach ($day in $days) {
      $items = @($plan.Items | Where-Object { $_.Day -eq $day })
      $zipFile = Join-Path $backupDir "$day.zip"
      try {
        $entries = Get-PLMAZipEntries $zipFile
      } catch {
        [void]$st.Fails.Add("day $day not saved: $($_.Exception.Message)")
        continue
      }
      $dayStage = Join-Path $stageRoot $day
      $toAdd = New-Object System.Collections.ArrayList
      $pending = @{}
      try {
        if (Test-Path -LiteralPath $dayStage) { Remove-Item -LiteralPath $dayStage -Recurse -Force }
        foreach ($it in $items) {
          if (-not $sizeCache.ContainsKey($it.ServerDir)) { $sizeCache[$it.ServerDir] = Get-PLMAServerSizes $src $it.ServerDir }
          $sizes = $sizeCache[$it.ServerDir]
          if (-not $sizes.ContainsKey($it.Name)) {
            [void]$st.Warns.Add("listed but missing on the server: $($it.Line)")
            continue
          }
          $size = [int64]$sizes[$it.Name]
          if ($entries.ContainsKey($it.ZipPath)) {
            if ([int64]$entries[$it.ZipPath] -eq $size) {
              [void]$verified.Add($it.Line)
            } else {
              [void]$st.Warns.Add("size on the server differs from the saved copy, not replaced and not listed: $($it.Line)")
            }
            continue
          }
          $staged = Join-Path (Join-Path $dayStage $it.Source) $it.Name
          try {
            Save-PLMAServerFile $src $it.Line $staged
          } catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
            [void]$st.Warns.Add("listed but missing on the server: $($it.Line)")
            continue
          }
          if ((Get-Item -LiteralPath $staged).Length -ne $size) {
            [void]$st.Warns.Add("size changed while copying, not saved: $($it.Line)")
            continue
          }
          [void]$toAdd.Add(@{ ZipPath = $it.ZipPath; StagedPath = $staged })
          $pending[$it.ZipPath] = $it.Line
        }
        if ($toAdd.Count -gt 0) {
          if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
          $added = Add-PLMAToDayZip $zipFile ([object[]]$toAdd.ToArray())
          foreach ($zp in $added) { [void]$verified.Add($pending[$zp]) }
          if ($added.Count -gt 0) { $newFiles += $added.Count; $zipsTouched++ }
        }
      } catch {
        [void]$st.Fails.Add("day $day not saved: $($_.Exception.Message)")
      } finally {
        if (Test-Path -LiteralPath $dayStage) { Remove-Item -LiteralPath $dayStage -Recurse -Force -ErrorAction SilentlyContinue }
      }
    }

    $suffix = 'Archived.txt not written'
    if ($mode -ceq 'Days') {
      $suffix = 'Archived.txt not written (Days mode)'
    } elseif ($mode -ceq 'Archived') {
      if ($NoUpload) {
        $suffix = 'Archived.txt not written (-NoUpload)'
      } else {
        $listed = New-Object System.Collections.ArrayList
        foreach ($it in $plan.Items) { if ($verified.Contains($it.Line)) { [void]$listed.Add($it.Line) } }
        $existingText = Read-PLMAServerText $src 'ProfileLogManager/Archived.txt'
        $existing = @()
        if ($null -ne $existingText) { $existing = @($existingText -split "`n") }
        $merged = Merge-PLMAArchivedLines ([string[]]$existing) ([string[]]$listed.ToArray())
        $have = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($e in $existing) { [void]$have.Add((ConvertTo-PLMACleanLine $e)) }
        $missing = 0
        foreach ($l in $listed) { if (-not $have.Contains($l)) { $missing++ } }
        if ($merged.Count -gt $script:PLMA_ARCHIVED_MAX) {
          $over = $merged.Count - $script:PLMA_ARCHIVED_MAX
          [void]$st.Warns.Add("Archived.txt holds the first $($script:PLMA_ARCHIVED_MAX) lines; $over more wait for the next run")
          $merged = [string[]]$merged[0..($script:PLMA_ARCHIVED_MAX - 1)]
        }
        if ($missing -eq 0) {
          $suffix = 'Archived.txt already up to date'
        } else {
          try {
            Publish-PLMAArchived $src ([string[]]$merged)
            $suffix = 'Archived.txt uploaded'
          } catch {
            [void]$st.Fails.Add("Archived.txt could not be written: $($_.Exception.Message)")
          }
        }
      }
    }

    $summary = "$newFiles files saved in $zipsTouched day zips, $suffix"
    if ($st.Fails.Count -gt 0) {
      return (Close-PLMARun $st ('FAILED: ' + $st.Fails[0] + " ($summary)") 2)
    }
    if ($st.Warns.Count -gt 0) { return (Close-PLMARun $st "OK with warnings: $summary" 1) }
    return (Close-PLMARun $st "OK: $summary" 0)
  } catch {
    return (Close-PLMARun $st ('FAILED: ' + $_.Exception.Message) 2)
  } finally {
    try { Close-PLMASource $src } catch { $null = $_ }
    if ($null -ne $lock) {
      $lock.Dispose()
      Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
    }
  }
}

function New-PLMATaskParts([string]$Name, [int]$Hours, [string]$ScriptPath) {
  $args1 = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '" -Run ' + $Name
  return @{
    Action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args1
    Trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours $Hours)
    Settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 6)
    Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
  }
}

function Set-PLMASchedule([hashtable]$Server, [string]$ScriptPath) {
  $taskName = 'PLMArchiver_' + [string]$Server.Name
  $hours = [int]$Server.ScheduleHours
  if ($hours -le 0) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    return
  }
  $parts = New-PLMATaskParts ([string]$Server.Name) $hours $ScriptPath
  $null = Register-ScheduledTask -TaskName $taskName -Action $parts.Action -Trigger $parts.Trigger -Settings $parts.Settings -Principal $parts.Principal -Force
}

function Read-PLMAAnswer([string]$Prompt, [string]$Default) {
  if ($Default) { $text = Read-Host "$Prompt [$Default]" } else { $text = Read-Host $Prompt }
  if ($null -eq $text -or $text.Trim() -eq '') { return $Default }
  return $text.Trim()
}

function Read-PLMASecret([string]$Prompt) {
  return (Read-Host $Prompt -AsSecureString)
}

function Test-PLMAName([string]$Name) {
  return ($Name -cmatch '^[A-Za-z0-9_-]{1,20}$')
}

function Get-PLMAServerFile([string]$Name, [string]$BaseDir) {
  return (Join-Path (Join-Path $BaseDir 'servers') "$Name.json")
}

function Get-PLMAServerNames([string]$BaseDir) {
  $dir = Join-Path $BaseDir 'servers'
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return , ([string[]]@()) }
  $names = New-Object System.Collections.ArrayList
  foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.json' -File)) {
    if (Test-PLMAName $f.BaseName) { [void]$names.Add($f.BaseName) }
  }
  $arr = [string[]]$names.ToArray()
  [Array]::Sort($arr, [StringComparer]::OrdinalIgnoreCase)
  return , $arr
}

function Get-PLMAServer([string]$Name, [string]$BaseDir) {
  if (-not (Test-PLMAName $Name)) { return $null }
  $file = Get-PLMAServerFile $Name $BaseDir
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
  try {
    $obj = [IO.File]::ReadAllText($file) | ConvertFrom-Json
  } catch {
    throw "$file could not be read: $($_.Exception.Message)"
  }
  if ($null -eq $obj) { throw "$file could not be read: it is empty" }
  $s = @{}
  foreach ($p in $obj.PSObject.Properties) { $s[$p.Name] = $p.Value }
  $s.Name = [string]$s.Name
  $s.Port = [int]$s.Port
  $s.ScheduleHours = [int]$s.ScheduleHours
  foreach ($k in @('Mode', 'HostName', 'UserName', 'Password', 'HostKey', 'ProfilePath', 'BackupFolder')) {
    if ($null -eq $s[$k]) { $s[$k] = '' } else { $s[$k] = [string]$s[$k] }
  }
  return $s
}

function Save-PLMAServer([hashtable]$Server, [string]$BaseDir) {
  if (-not (Test-PLMAName ([string]$Server.Name))) { throw "bad server name '$($Server.Name)'" }
  $dir = Join-Path $BaseDir 'servers'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $out = [ordered]@{
    Name          = [string]$Server.Name
    Mode          = [string]$Server.Mode
    HostName      = [string]$Server.HostName
    Port          = [int]$Server.Port
    UserName      = [string]$Server.UserName
    Password      = [string]$Server.Password
    HostKey       = [string]$Server.HostKey
    ProfilePath   = [string]$Server.ProfilePath
    BackupFolder  = [string]$Server.BackupFolder
    ScheduleHours = [int]$Server.ScheduleHours
  }
  $file = Get-PLMAServerFile ([string]$Server.Name) $BaseDir
  $tmp = "$file.tmp"
  [IO.File]::WriteAllText($tmp, ($out | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
  if (Test-Path -LiteralPath $file) {
    [IO.File]::Replace($tmp, $file, [NullString]::Value)
  } else {
    [IO.File]::Move($tmp, $file)
  }
}

function Remove-PLMAServer([string]$Name, [string]$BaseDir) {
  try {
    $s = Get-PLMAServer $Name $BaseDir
  } catch {
    $s = @{ Name = $Name }
  }
  if ($null -eq $s) { return }
  $off = @{}
  foreach ($k in $s.Keys) { $off[$k] = $s[$k] }
  $off.ScheduleHours = 0
  $null = Set-PLMASchedule $off $script:PLMA_Script
  Remove-Item -LiteralPath (Get-PLMAServerFile $Name $BaseDir) -Force
}

function Read-PLMAChoice([string]$Prompt, [string]$Default, [string[]]$Allowed) {
  while ($true) {
    $a = Read-PLMAAnswer $Prompt $Default
    foreach ($ok in $Allowed) { if ($a -ieq $ok) { return $ok.ToUpper() } }
    Write-Host ('Please answer ' + ($Allowed -join ' or ') + '.')
  }
}

function Read-PLMANumber([string]$Prompt, [string]$Default, [int]$Min, [int]$Max) {
  while ($true) {
    $a = Read-PLMAAnswer $Prompt $Default
    $n = 0
    if ([int]::TryParse($a, [ref]$n) -and $n -ge $Min -and $n -le $Max) { return $n }
    Write-Host "Please enter a whole number from $Min to $Max."
  }
}

function Resolve-PLMAFullPath([string]$Path) {
  if (-not $Path) { return '' }
  try {
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  } catch { return '' }
  if (-not (Test-PLMAFullPath $full)) { return '' }
  return $full
}

function Invoke-PLMASetupCore([string]$BaseDir) {
  $names = Get-PLMAServerNames $BaseDir
  $name = $null
  $choice = 'N'
  if ($names.Count -gt 0) {
    Write-Host 'Saved servers:'
    for ($i = 0; $i -lt $names.Count; $i++) { Write-Host ("  {0}  {1}" -f ($i + 1), $names[$i]) }
    while ($true) {
      $a = Read-PLMAAnswer 'Pick a number, N for a new server, D to delete one' ''
      if ($a -ieq 'N') { $choice = 'N'; break }
      if ($a -ieq 'D') { $choice = 'D'; break }
      $n = 0
      if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $names.Count) { $choice = 'P'; $name = $names[$n - 1]; break }
      Write-Host 'Please pick one of the numbers, N or D.'
    }
  }
  if ($choice -eq 'D') {
    $n = Read-PLMANumber 'Number of the server to delete' '' 1 $names.Count
    $victim = $names[$n - 1]
    $yn = Read-PLMAChoice "Delete $victim and its scheduled task? Backups and logs stay. (Y/N)" 'N' @('Y', 'N')
    if ($yn -ne 'Y') { Write-Host 'Nothing deleted.'; return 2 }
    $null = Remove-PLMAServer $victim $BaseDir
    Write-Host "Deleted $victim."
    return 0
  }
  if ($choice -eq 'N') {
    while ($true) {
      $name = Read-PLMAAnswer 'Short name for this server (letters, digits, _ and -, up to 20)' ''
      if (Test-PLMAName $name) { break }
      Write-Host 'That name is not allowed.'
    }
  }
  try {
    $old = Get-PLMAServer $name $BaseDir
  } catch {
    Write-Host "The saved settings for $name could not be read; starting from blank answers."
    $old = $null
  }
  if ($null -eq $old) {
    $old = @{ Mode = ''; HostName = ''; Port = 22; UserName = ''; Password = ''; HostKey = ''; ProfilePath = ''; BackupFolder = ''; ScheduleHours = 168 }
  }
  $srv = @{ Name = $name; Mode = 'Local'; HostName = ''; Port = 22; UserName = ''; Password = ''; HostKey = ''; ProfilePath = ''; BackupFolder = ''; ScheduleHours = 168 }

  $defMode = ''
  if ($old.Mode -eq 'Remote') { $defMode = 'R' } elseif ($old.Mode -eq 'Local') { $defMode = 'L' }
  $m = Read-PLMAChoice 'Remote (R) or local (L) server?' $defMode @('R', 'L')

  if ($m -eq 'R') {
    $srv.Mode = 'Remote'
    while ($true) {
      $srv.HostName = Read-PLMAAnswer 'Host name or address' ([string]$old.HostName)
      if ($srv.HostName) { break }
    }
    $srv.Port = Read-PLMANumber 'Port' ([string]$old.Port) 1 65535
    while ($true) {
      $srv.UserName = Read-PLMAAnswer 'User name' ([string]$old.UserName)
      if ($srv.UserName) { break }
    }
    while ($true) {
      if ($old.Password) { $label = 'Password (saved, Enter keeps it)' } else { $label = 'Password (typed hidden)' }
      $sec = Read-PLMASecret $label
      if ($null -ne $sec -and $sec.Length -gt 0) {
        $srv.Password = ConvertFrom-SecureString $sec
        break
      }
      if ($old.Password) { $srv.Password = [string]$old.Password; break }
      Write-Host 'A password is needed.'
    }
    Write-Host "Scanning the host key of $($srv.HostName):$($srv.Port) ..."
    try {
      $key = Get-PLMAHostKey $srv.HostName $srv.Port
    } catch {
      Write-Host "Could not read the host key: $($_.Exception.Message)"
      Write-Host 'Nothing saved.'
      return 2
    }
    Write-Host "Host key: $key"
    $savedKey = [string]$old.HostKey
    if ($savedKey -and $savedKey -ceq $key) {
      Write-Host 'The host key matches the saved key.'
    } else {
      if ($savedKey) {
        Write-Host 'WARNING: the host key has CHANGED from the saved key.'
        Write-Host "Saved key: $savedKey"
        Write-Host 'Answer Y only if you moved this server to a new host on purpose.'
      }
      $yn = Read-PLMAChoice 'Is this your server? (Y/N)' '' @('Y', 'N')
      if ($yn -ne 'Y') { Write-Host 'Nothing saved.'; return 2 }
    }
    $srv.HostKey = $key
    $srv.ProfilePath = Read-PLMAAnswer 'The server profile folder (remote path)' ([string]$old.ProfilePath)
  } else {
    while ($true) {
      $srv.ProfilePath = Resolve-PLMAFullPath (Read-PLMAAnswer 'The server profile folder' ([string]$old.ProfilePath))
      if ($srv.ProfilePath -and (Test-Path -LiteralPath $srv.ProfilePath -PathType Container)) { break }
      Write-Host "That folder does not exist: $($srv.ProfilePath)"
    }
  }

  while ($true) {
    $srv.BackupFolder = Resolve-PLMAFullPath (Read-PLMAAnswer 'Backup folder' ([string]$old.BackupFolder))
    if ($srv.BackupFolder) { break }
    Write-Host 'Please give a folder on this PC.'
  }
  if (-not (Test-Path -LiteralPath $srv.BackupFolder)) {
    try {
      New-Item -ItemType Directory -Force -Path $srv.BackupFolder | Out-Null
      Write-Host "Created $($srv.BackupFolder)"
    } catch {
      Write-Host "Could not create the backup folder: $($_.Exception.Message)"
      return 2
    }
  }
  $srv.ScheduleHours = Read-PLMANumber 'Run every how many hours (0 = no schedule, at most 744)' ([string]$old.ScheduleHours) 0 744

  Write-Host 'Testing the connection ...'
  $ok = $false
  $src = $null
  try {
    $src = Open-PLMASource $srv (Join-Path (Join-Path $BaseDir 'work') "$name.setup")
    $text = Read-PLMAServerText $src 'ProfileLogManager/Settings.json'
    if ($null -eq $text) { throw 'ProfileLogManager/Settings.json not found (is Profile Log Manager installed and has the server run once?)' }
    $set = $text | ConvertFrom-Json
    if ($null -eq $set) { throw 'Settings.json is empty' }
    Write-Host "Connected. PLM_LogFolder = $($set.PLM_LogFolder), PLM_DeleteMode = $($set.PLM_DeleteMode)"
    $ok = $true
  } catch {
    Write-Host "Test failed: $($_.Exception.Message)"
  } finally {
    try { Close-PLMASource $src } catch { $null = $_ }
  }
  if (-not $ok) {
    $yn = Read-PLMAChoice 'Save anyway? (Y/N)' 'N' @('Y', 'N')
    if ($yn -ne 'Y') { Write-Host 'Nothing saved.'; return 2 }
  }

  Save-PLMAServer $srv $BaseDir
  Write-Host "Saved $name."
  try {
    $null = Set-PLMASchedule $srv $script:PLMA_Script
  } catch {
    Write-Host "Saved, but the schedule could not be set: $($_.Exception.Message)"
    return 2
  }
  return 0
}

function Invoke-PLMASetup([string]$BaseDir) {
  $rc = Invoke-PLMASetupCore $BaseDir
  $null = Read-PLMAAnswer 'Press Enter to close' ''
  return [int]$rc
}

function Start-PLMA([string]$Run, [switch]$NoUpload, [string]$BaseDir = $script:PLMA_Dir) {
  if ($Run) {
    try {
      $server = Get-PLMAServer $Run $BaseDir
    } catch {
      $st = @{ BaseDir = $BaseDir; Name = $Run; Fails = @($_.Exception.Message); Warns = @() }
      return (Close-PLMARun $st "FAILED: settings for $Run could not be read - run setup" 2)
    }
    if ($null -eq $server) {
      Write-Host "FAILED: no server named $Run - run setup"
      return 2
    }
    return (Invoke-PLMARun $server -NoUpload:$NoUpload -BaseDir $BaseDir)
  }
  return (Invoke-PLMASetup $BaseDir)
}

if ($MyInvocation.InvocationName -ne '.') { exit (Start-PLMA -Run $Run -NoUpload:$NoUpload) }
