# 클로드 코드 자동 설정 스크립트
# 이 파일을 직접 열 필요 없음. 옆의 "클로드-설정하기.bat" 을 더블클릭하면 실행됨.
# 하는 일: 사전 점검 -> 노드JS/깃/파이썬 설치 -> 클로드 코드 설치 -> PATH 등록
#          -> .env 의 키로 settings.json 작성 -> 연결 확인

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------------------------------------------------------------- 공통 함수
function Say   ($t) { Write-Host $t }
function Title ($t) { Write-Host ''; Write-Host $t -ForegroundColor Cyan }
function Step  ($t) {
    $w = 0
    foreach ($ch in $t.ToCharArray()) { if ([int]$ch -gt 0x1100) { $w += 2 } else { $w += 1 } }
    $pad = 24 - $w
    if ($pad -lt 1) { $pad = 1 }
    Write-Host ('  - ' + $t + (' ' * $pad)) -NoNewline
}
function Ok    ($t) { Write-Host ('   [확인] ' + $t) -ForegroundColor Green }
function Warn  ($t) { Write-Host ('   [주의] ' + $t) -ForegroundColor Yellow }
function Fail  ($t) { Write-Host ('   [실패] ' + $t) -ForegroundColor Red }
function Ask   ($t) { return (Read-Host ('  ' + $t)).Trim().ToLower() }
function Yes   ($t) { return ((Ask ($t + ' (y/n)')) -eq 'y') }

function Stop-Here ($msg) {
    try { Stop-Transcript | Out-Null } catch {}
    Write-Host ''
    Write-Host '==========================================' -ForegroundColor Red
    Write-Host '  설정을 끝내지 못했습니다' -ForegroundColor Red
    Write-Host '==========================================' -ForegroundColor Red
    Write-Host ('  ' + $msg)
    Write-Host ''
    exit 1
}

# 어떤 객체에 그 속성이 있는지 확인.
# $obj.PSObject.Properties.Name 을 쓰면 속성이 하나도 없는 객체에서
# 엄격 모드(Set-StrictMode)일 때 오류가 나므로 하나씩 훑는 방식으로 확인한다.
function Has-Prop ($obj, $name) {
    if ($null -eq $obj) { return $false }
    $props = $obj.PSObject.Properties
    if ($null -eq $props) { return $false }
    foreach ($p in $props) { if ($p.Name -eq $name) { return $true } }
    return $false
}

function Set-Prop ($obj, $name, $value) {
    if ($null -eq $obj) { return }
    if (Has-Prop $obj $name) { $obj.$name = $value }
    else { Add-Member -InputObject $obj -NotePropertyName $name -NotePropertyValue $value -Force }
}

function Read-DotEnv ($path) {
    $map = @{}
    # 메모장이 어떤 인코딩으로 저장했든 읽히도록 파일 앞부분(BOM)을 보고 판단
    $b = [System.IO.File]::ReadAllBytes($path)
    if     ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $text = [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
    elseif ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { $text = [Text.Encoding]::BigEndianUnicode.GetString($b, 2, $b.Length - 2) }
    elseif ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $text = [Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3) }
    else { $text = [Text.Encoding]::UTF8.GetString($b) }
    foreach ($line in ($text -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $t.Substring(0, $i).Trim()
        $v = $t.Substring($i + 1).Trim().Trim([char]34).Trim([char]39)
        $map[$k] = $v
    }
    return $map
}

function Mask-Key ($k) {
    if ($k.Length -gt 12) { return $k.Substring(0, 4) + '...' + $k.Substring($k.Length - 4) }
    return '****'
}

# ---------------------------------------------------------------- 설치용 공통 함수
# 설치 프로그램이 PATH 를 바꿔도 지금 창은 옛날 값을 들고 있음. 그래서 매번 새로 읽어 옴
# PATH 가 망가진 PC 에서도 where.exe, msiexec 같은 윈도우 기본 명령을 찾게 해 줌
function Add-BasePath {
    $sys = $env:SystemRoot
    if (-not $sys) { $sys = 'C:\Windows' }
    $need = @(
        (Join-Path $sys 'System32'),
        $sys,
        (Join-Path $sys 'System32\Wbem'),
        (Join-Path $sys 'System32\WindowsPowerShell\v1.0')
    )
    foreach ($d in $need) {
        if (-not (Test-Path $d)) { continue }
        $have = @($env:PATH -split ';' | ForEach-Object { $_.Trim().TrimEnd('\').ToLower() })
        if ($have -notcontains $d.TrimEnd('\').ToLower()) { $env:PATH = $d + ';' + $env:PATH }
    }
}

function Refresh-Path {
    $m = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $env:PATH = (@($m, $u) | Where-Object { $_ -and $_.Trim() -ne '' }) -join ';'
    Add-BasePath
}

function Where-Cmd ($name) {
    $found = @(Get-Command $name -CommandType Application -ErrorAction SilentlyContinue)
    return @($found | ForEach-Object { "$($_.Source)".Trim() } | Where-Object { $_ -ne '' })
}

function Has-Cmd ($name) { return ((Where-Cmd $name).Count -gt 0) }

# 요즘 노트북에는 ARM64 도 있음. 설치 파일을 직접 받을 때 종류를 맞춰야 함
function Get-Arch {
    $a = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $a = $env:PROCESSOR_ARCHITEW6432 }
    switch ("$a".ToUpper()) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        'X86'   { return 'x86' }
        default { return 'x64' }
    }
}

function Get-NodeVersion {
    if (-not (Has-Cmd 'node')) { return $null }
    try { return [string]((& node --version 2>$null) | Select-Object -First 1) } catch { return $null }
}

function Get-GitVersion {
    if (-not (Has-Cmd 'git')) { return $null }
    try { return [string]((& git --version 2>$null) | Select-Object -First 1) } catch { return $null }
}

# 윈도우에는 스토어로 연결되는 가짜 python.exe 가 있음. 그건 설치된 것으로 치지 않음
function Get-PythonVersion {
    foreach ($p in (Where-Cmd 'python')) {
        if ($p -like '*\Microsoft\WindowsApps\*') { continue }
        try { $v = (& $p --version 2>$null) | Select-Object -First 1 } catch { $v = $null }
        if ($v) { return [string]$v }
    }
    if (Has-Cmd 'py') {
        try { $v = (& py -3 --version 2>$null) | Select-Object -First 1 } catch { $v = $null }
        if ($v) { return [string]$v }
    }
    return $null
}

function Download-File ($url, $dest) {
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 900 }
    finally { $ProgressPreference = $old }
}

function Install-ByWinget ($id) {
    if (-not $script:HasWinget) { return }
    Say ('    winget 으로 설치합니다: ' + $id)
    Say '    (사용자 계정 컨트롤 창이 뜨면 [예] 를 누르세요)'
    try {
        & winget install --id $id -e --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
    } catch {
        Warn ('winget 설치 중 오류: ' + $_.Exception.Message)
    }
    Refresh-Path
}

function Run-Installer ($file, $argList, $elevate) {
    Say '    설치 중입니다. 사용자 계정 컨트롤 창이 뜨면 [예] 를 누르세요...'
    try {
        if ($elevate) { $p = Start-Process -FilePath $file -ArgumentList $argList -Verb RunAs -Wait -PassThru }
        else          { $p = Start-Process -FilePath $file -ArgumentList $argList -Wait -PassThru }
        Refresh-Path
        return ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010)
    } catch {
        Warn ('설치 실행 실패: ' + $_.Exception.Message)
        return $false
    }
}

function Install-NodeDirect {
    try {
        Say '    nodejs.org 에서 최신 LTS 설치 파일을 내려받습니다...'
        $idx = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 60
        $lts = @($idx | Where-Object { $_.lts }) | Select-Object -First 1
        if (-not $lts) { Warn 'LTS 버전을 찾지 못했습니다'; return }
        $arch = Get-Arch
        if ($arch -eq 'x86') { Warn '32비트 윈도우는 노드JS 설치 파일이 더 이상 제공되지 않습니다'; return }
        $name = 'node-' + $lts.version + '-' + $arch + '.msi'
        $url = 'https://nodejs.org/dist/' + $lts.version + '/' + $name
        $dst = Join-Path $script:TempDir $name
        Download-File $url $dst
        Run-Installer 'msiexec.exe' @('/i', ('"' + $dst + '"'), '/qn', '/norestart') $true | Out-Null
    } catch {
        Warn ('노드JS 설치 실패: ' + $_.Exception.Message)
    }
}

function Install-GitDirect {
    try {
        Say '    git-scm.com 에서 설치 파일을 내려받습니다...'
        $hdr = @{ 'User-Agent' = 'claude-class-setup' }
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' -Headers $hdr -TimeoutSec 60
        $arch = Get-Arch
        if ($arch -eq 'arm64') { $pat = '^Git-.*-arm64\.exe$' }
        elseif ($arch -eq 'x86') { $pat = '^Git-.*-32-bit\.exe$' }
        else { $pat = '^Git-.*-64-bit\.exe$' }
        $asset = @($rel.assets | Where-Object { $_.name -match $pat }) | Select-Object -First 1
        if (-not $asset) { $asset = @($rel.assets | Where-Object { $_.name -match '^Git-.*-64-bit\.exe$' }) | Select-Object -First 1 }
        if (-not $asset) { Warn '설치 파일을 찾지 못했습니다'; return }
        $dst = Join-Path $script:TempDir $asset.name
        Download-File $asset.browser_download_url $dst
        Run-Installer $dst @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-') $true | Out-Null
    } catch {
        Warn ('깃 설치 실패: ' + $_.Exception.Message)
    }
}

function Install-PythonDirect {
    try {
        $pv = '3.12.10'
        Say ('    python.org 에서 파이썬 ' + $pv + ' 설치 파일을 내려받습니다...')
        $arch = Get-Arch
        if     ($arch -eq 'arm64') { $name = 'python-' + $pv + '-arm64.exe' }
        elseif ($arch -eq 'x86')   { $name = 'python-' + $pv + '.exe' }
        else                       { $name = 'python-' + $pv + '-amd64.exe' }
        $url = 'https://www.python.org/ftp/python/' + $pv + '/' + $name
        $dst = Join-Path $script:TempDir $name
        Download-File $url $dst
        # 내 계정에만 설치 = 관리자 권한이 필요 없음. PrependPath 로 PATH 자동 등록
        Run-Installer $dst @('/quiet', 'InstallAllUsers=0', 'PrependPath=1', 'Include_pip=1', 'Include_tcltk=1', 'Include_test=0') $false | Out-Null
    } catch {
        Warn ('파이썬 설치 실패: ' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------- 시작
$ScriptDir   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$EnvPath     = Join-Path $ScriptDir '.env'
$DefaultUrl  = 'https://factchat-cloud.mindlogic.ai/v1/gateway/claude'
$BinDir      = Join-Path $env:USERPROFILE '.local\bin'
$ClaudeExe   = Join-Path $BinDir 'claude.exe'
$Placeholder = 'PUT-YOUR-KEY-HERE'

# 레지스트리의 진짜 PATH 를 읽어 와서 시작 (부모 창의 PATH 가 망가져 있어도 됨)
Refresh-Path

# 화면에 지나간 내용을 파일로 남겨 둠. 오류가 나면 이 파일만 보내면 원인을 알 수 있음
$LogPath = Join-Path $ScriptDir '설정-기록.txt'
try { Start-Transcript -Path $LogPath -Append -ErrorAction Stop | Out-Null }
catch {
    $LogPath = Join-Path $env:TEMP 'claude-설정-기록.txt'
    try { Start-Transcript -Path $LogPath -Append -ErrorAction Stop | Out-Null }
    catch { $LogPath = '(기록 파일을 만들지 못했습니다)' }
}

# 답답해서 bat 을 두 번 누르면 설정 파일을 동시에 건드려 저장이 깨짐. 그래서 한 번에 하나만 돌게 함
$SetupMutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeClassSetup')
if (-not $SetupMutex.WaitOne(0)) {
    Write-Host ''
    Write-Host '  이미 다른 설정 창이 실행 중입니다.' -ForegroundColor Yellow
    Write-Host '  먼저 열린 창이 끝난 뒤에 다시 실행하세요.' -ForegroundColor Yellow
    Write-Host '  (두 번 눌러도 빨라지지 않고, 오히려 설정이 꼬입니다)' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

$script:HasWinget = $false
$script:TempDir   = Join-Path $env:TEMP 'claude-class-setup'
if (-not (Test-Path $script:TempDir)) { New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null }

Write-Host '==========================================' -ForegroundColor Cyan
Write-Host '   클로드 코드 수업용 자동 설정' -ForegroundColor Cyan
Write-Host '==========================================' -ForegroundColor Cyan
Say ''
Say '  하는 일'
Say '   1. 사전 점검 (윈도우, 인터넷, 팩트챗 서버)'
Say '   2. 노드JS / 깃 / 파이썬 설치 (이미 있으면 건너뜀)'
Say '   3. 기존 클로드 확인 (npm 버전이 있으면 정리)'
Say '   4. 클로드 코드 설치'
Say '   5. PATH 등록'
Say '   6. .env 에 적어 둔 키 읽기'
Say '   7. settings.json 작성 + 연결 확인'
Say ''
Say ('  실행 폴더: ' + $ScriptDir)
Say '  준비물: 팩트챗에서 발급받은 API 키 1개, 인터넷 연결'
Say '  설치 도중 "이 앱이 장치를 변경하도록 허용할까요?" 창이 뜨면 [예] 를 누르세요.'

# ================================================================ 1. 사전 점검
Title '[1/7] 사전 점검'

Step 'PowerShell 버전'
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Fail ([string]$PSVersionTable.PSVersion + ' - 5.1 이상이 필요합니다')
    Stop-Here 'Windows 업데이트 후 다시 시도하세요.'
}
Ok ([string]$PSVersionTable.PSVersion)

Step '프로세서'
$arch = Get-Arch
if ($arch -eq 'x86') { Warn ($arch + ' - 32비트 윈도우는 설치 파일이 제공되지 않을 수 있습니다') }
else { Ok $arch }

Step '인터넷 연결'
$netOk = $false
try {
    Invoke-WebRequest -Uri 'https://claude.ai' -Method Head -TimeoutSec 15 -UseBasicParsing | Out-Null
    $netOk = $true
} catch {
    if ($_.Exception.Response) { $netOk = $true }
}
if ($netOk) { Ok '정상' }
else {
    Fail '인터넷에 연결되지 않았습니다'
    Stop-Here 'Wi-Fi 연결을 확인한 뒤 다시 실행하세요.'
}

Step '팩트챗 서버'
$gwOk = $false
try {
    Invoke-WebRequest -Uri $DefaultUrl -Method Head -TimeoutSec 15 -UseBasicParsing | Out-Null
    $gwOk = $true
} catch {
    if ($_.Exception.Response) { $gwOk = $true }
}
if ($gwOk) { Ok '응답함' }
else { Warn '응답이 없습니다 (학교망 또는 방화벽 문제일 수 있음). 계속 진행합니다.' }

Step '설치 도구(winget)'
if (Has-Cmd 'winget') { $script:HasWinget = $true; Ok '사용 가능' }
else { Warn '없음 - 공식 홈페이지에서 설치 파일을 직접 내려받습니다' }

Step '.env 파일'
if (Test-Path $EnvPath) { Ok $EnvPath }
else {
    Fail ('.env 파일이 없습니다: ' + $EnvPath)
    Stop-Here 'bat 파일과 .env 파일을 같은 폴더에 두고 다시 실행하세요.'
}

# ================================================================ 2. 필수 프로그램 설치
Title '[2/7] 노드JS / 깃 / 파이썬 설치'
Say '  이미 설치되어 있으면 건드리지 않고 버전만 확인합니다.'
Refresh-Path

# --- 노드JS
Step '노드JS(Node.js)'
$nodeVer  = Get-NodeVersion
$needNode = $false
if ($nodeVer) {
    $major = 0
    if ($nodeVer -match 'v?(\d+)\.') { $major = [int]$matches[1] }
    if ($major -ge 18) {
        Ok ($nodeVer + ' - 이미 설치됨')
    } else {
        Write-Host ''
        Warn ('버전이 너무 낮습니다: ' + $nodeVer + ' (18 이상 권장)')
        if (Yes '최신 LTS 로 올릴까요?') { $needNode = $true } else { Warn '그대로 두고 진행합니다' }
    }
} else {
    Write-Host ''
    Say '    설치되어 있지 않습니다. 지금 설치합니다.'
    $needNode = $true
}
if ($needNode) {
    if ($script:HasWinget) { Install-ByWinget 'OpenJS.NodeJS.LTS' }
    if (-not (Get-NodeVersion)) { Install-NodeDirect }
    Step '노드JS 설치 결과'
    $nodeVer = Get-NodeVersion
    if ($nodeVer) { Ok $nodeVer }
    else { Warn '확인 실패 -> https://nodejs.org/ko 에서 직접 설치하세요' }
}

# --- 깃
Step '깃(Git)'
$gitVer = Get-GitVersion
if ($gitVer) {
    Ok ($gitVer + ' - 이미 설치됨')
} else {
    Write-Host ''
    Say '    설치되어 있지 않습니다. 지금 설치합니다.'
    if ($script:HasWinget) { Install-ByWinget 'Git.Git' }
    if (-not (Get-GitVersion)) { Install-GitDirect }
    Step '깃 설치 결과'
    $gitVer = Get-GitVersion
    if ($gitVer) { Ok $gitVer }
    else { Warn '확인 실패 -> https://git-scm.com 에서 직접 설치하세요' }
}

# --- 파이썬 (손글씨 인식 실습에서 사용)
Step '파이썬(Python)'
$pyVer = Get-PythonVersion
if ($pyVer) {
    Ok ($pyVer + ' - 이미 설치됨')
} else {
    Write-Host ''
    Say '    설치되어 있지 않습니다. 실습 코드 실행에 필요하므로 지금 설치합니다.'
    if ($script:HasWinget) { Install-ByWinget 'Python.Python.3.12' }
    if (-not (Get-PythonVersion)) { Install-PythonDirect }
    Step '파이썬 설치 결과'
    $pyVer = Get-PythonVersion
    if ($pyVer) { Ok $pyVer }
    else { Warn '확인 실패 -> https://www.python.org/downloads 에서 직접 설치하세요' }
}

Refresh-Path

# ================================================================ 3. 기존 클로드 설치 확인
Title '[3/7] 기존 클로드 설치 확인'

$paths  = Where-Cmd 'claude'
$npmVer = @($paths | Where-Object { $_ -like '*\npm\*' -or $_ -like '*node_modules*' })

Step '설치 경로 확인'
if ($paths.Count -eq 0) {
    Ok '설치 흔적 없음 (신규 설치 대상)'
} else {
    Write-Host ''
    foreach ($p in $paths) { Say ('      ' + $p) }
}

if ($npmVer.Count -gt 0) {
    Warn 'npm 으로 설치된 예전 버전이 남아 있습니다. 그대로 두면 충돌이 납니다.'
    if (Yes 'npm 버전을 제거할까요?') {
        try {
            & npm.cmd uninstall -g '@anthropic-ai/claude-code'
            Ok 'npm 제거 명령을 실행했습니다'
        } catch {
            Warn ('npm 제거 중 오류: ' + $_.Exception.Message)
        }
        $left = @((Where-Cmd 'claude') | Where-Object { $_ -like '*\npm\*' -or $_ -like '*node_modules*' })
        foreach ($p in $left) {
            Warn ('파일이 남아 있습니다: ' + $p)
            if (Yes '위 파일을 삭제할까요?') {
                try { Remove-Item $p -Force; Ok '삭제함' }
                catch { Fail ('삭제 실패: ' + $_.Exception.Message) }
            } else {
                Warn '남겨 두었습니다. 나중에 충돌이 날 수 있습니다.'
            }
        }
    } else {
        Warn '제거하지 않고 진행합니다. claude 실행이 이상하면 이 파일을 다시 실행하세요.'
    }
}

# ================================================================ 4. 설치
Title '[4/7] 클로드 코드 설치'

if (Test-Path $ClaudeExe) {
    Step '설치 상태'
    Ok ('이미 설치되어 있습니다: ' + $ClaudeExe)
} else {
    Say '  네이티브 인스톨러를 내려받아 실행합니다.'
    Say '  (실행할 명령: irm https://claude.ai/install.ps1 | iex)'
    if (-not (Yes '지금 설치할까요?')) { Stop-Here '설치를 건너뛰어 더 진행할 수 없습니다.' }
    try {
        $installer = Invoke-RestMethod -Uri 'https://claude.ai/install.ps1' -TimeoutSec 60
        # & { } 로 감싸 별도 스코프에서 실행 -> 설치 스크립트가 바꾼 설정이 밖으로 새지 않음
        & { Invoke-Expression $script:installer }
    } catch {
        Fail ('설치 중 오류: ' + $_.Exception.Message)
        Stop-Here 'PowerShell 을 새로 열고 다시 시도하거나, 담당 교수에게 문의하세요.'
    }
    # 혹시라도 설치 스크립트의 설정이 새어 나왔을 경우를 대비해 원래대로 되돌림
    Set-StrictMode -Off
    $ErrorActionPreference = 'Stop'

    if (Test-Path $ClaudeExe) {
        Step '설치 결과'
        Ok $ClaudeExe
    } else {
        Fail '.local\bin\claude.exe 를 찾지 못했습니다'
        Stop-Here 'npm 버전이 완전히 제거되지 않았을 수 있습니다. 이 파일을 다시 실행해 3단계부터 확인하세요.'
    }
}

# ================================================================ 5. PATH 등록
Title '[5/7] PATH 등록'

$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($null -eq $userPath) { $userPath = '' }
$already = @($userPath -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') }) -contains $BinDir.TrimEnd('\')

Step 'PATH'
if ($already) {
    Ok '이미 등록되어 있습니다'
} else {
    if ($userPath.Trim() -eq '') { $newPath = $BinDir }
    else { $newPath = $userPath.TrimEnd(';') + ';' + $BinDir }
    [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
    Ok ('등록함 -> ' + $BinDir)
}
if (@($env:PATH -split ';') -notcontains $BinDir) {
    $env:PATH = $env:PATH.TrimEnd(';') + ';' + $BinDir
}

Step '버전 확인'
try {
    $ver = & $ClaudeExe --version 2>&1 | Select-Object -First 1
    Ok ([string]$ver)
} catch {
    Warn '버전 확인에 실패했지만 계속 진행합니다'
}

# ================================================================ 6. .env 에서 키 읽기
Title '[6/7] .env 에서 키 읽기'

$key = ''
$model = ''
$baseUrl = ''

for ($try = 1; $try -le 3; $try++) {
    $cfg     = Read-DotEnv $EnvPath
    $key     = [string]$cfg['ANTHROPIC_AUTH_TOKEN']
    $model   = [string]$cfg['ANTHROPIC_MODEL']
    $baseUrl = [string]$cfg['ANTHROPIC_BASE_URL']

    if ([string]::IsNullOrWhiteSpace($model))   { $model   = 'claude-haiku-4-5-20251001' }
    if ([string]::IsNullOrWhiteSpace($baseUrl)) { $baseUrl = $DefaultUrl }

    $bad = $null
    if ([string]::IsNullOrWhiteSpace($key)) { $bad = 'ANTHROPIC_AUTH_TOKEN 값이 비어 있습니다' }
    elseif ($key -eq $Placeholder)          { $bad = '키를 아직 붙여넣지 않았습니다' }
    elseif ($key.Length -lt 20)             { $bad = '키가 너무 짧습니다 (일부만 복사된 것 같습니다)' }
    elseif ($key -match '\s')               { $bad = '키 안에 공백이 있습니다' }
    elseif ($key -match '[가-힣]')          { $bad = '키에 한글이 섞여 있습니다' }

    if (-not $bad) {
        Step '키'
        Ok ((Mask-Key $key) + ' (' + $key.Length + '자)')
        break
    }

    Fail $bad
    if ($try -eq 3) { Stop-Here ('.env 를 열어 키를 넣고 저장한 뒤 다시 실행하세요: ' + $EnvPath) }
    Say ''
    Say '  메모장으로 .env 를 엽니다.'
    Say '  ANTHROPIC_AUTH_TOKEN= 뒤에 키를 붙여넣고 Ctrl+S 로 저장한 다음 메모장을 닫으세요.'
    Say ''
    Start-Process notepad.exe -ArgumentList $EnvPath -Wait
}

Step '모델'
Ok $model
Step '접속주소'
Ok $baseUrl

# ================================================================ 7. settings.json 작성
Title '[7/7] settings.json 작성'

$dir  = Join-Path $env:USERPROFILE '.claude'
$path = Join-Path $dir 'settings.json'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

# 클로드 코드가 켜져 있으면 설정 파일이 잠겨서 저장에 실패함
$running = @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Warn ('클로드 코드가 실행 중입니다 (' + $running.Count + '개). 그대로 두면 저장이 실패할 수 있습니다.')
    Say '  열려 있는 클로드 창에서 /exit 로 종료한 뒤 Enter 를 누르세요.'
    Read-Host '  준비되면 Enter' | Out-Null
}

$saved   = $false
$saveErr = ''
for ($sTry = 1; $sTry -le 3; $sTry++) {
    try {
        $settings = $null
        if (Test-Path $path) {
            $backup = $path + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item $path $backup -Force
            if ($sTry -eq 1) {
                Step '기존 설정 백업'
                Ok $backup
            }

            $raw = Get-Content $path -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                try {
                    $settings = $raw | ConvertFrom-Json
                } catch {
                    Warn '기존 settings.json 형식이 깨져 있어 읽을 수 없습니다 (원본은 백업에 있음)'
                    if (-not (Yes '새로 만들까요?')) { Stop-Here '아무것도 바꾸지 않았습니다.' }
                    $settings = $null
                }
            }
        }
        if ($null -eq $settings) { $settings = [pscustomobject]@{} }

        if ((Has-Prop $settings 'env') -and $settings.env) { $envObj = $settings.env }
        else { $envObj = [pscustomobject]@{} }

        Set-Prop $envObj 'ANTHROPIC_BASE_URL'   $baseUrl
        Set-Prop $envObj 'ANTHROPIC_AUTH_TOKEN' $key
        Set-Prop $envObj 'ANTHROPIC_MODEL'      $model
        Set-Prop $settings 'env' $envObj

        $json = $settings | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))

        $back  = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $check = $null
        if (Has-Prop $back 'env') { $check = $back.env }
        if (-not (Has-Prop $check 'ANTHROPIC_BASE_URL') -or
            -not (Has-Prop $check 'ANTHROPIC_AUTH_TOKEN') -or
            -not (Has-Prop $check 'ANTHROPIC_MODEL') -or
            $check.ANTHROPIC_BASE_URL -ne $baseUrl -or
            $check.ANTHROPIC_AUTH_TOKEN -ne $key -or
            $check.ANTHROPIC_MODEL -ne $model) {
            throw '저장한 값이 다시 읽은 값과 다릅니다 (저장 도중 다른 프로그램이 파일을 건드린 것 같습니다)'
        }

        $saved = $true
        break
    } catch {
        $saveErr = $_.Exception.Message
        if ($sTry -lt 3) {
            Write-Host ''
            Warn ('저장 실패 - 2초 뒤 다시 시도합니다 (' + $sTry + '/3): ' + $saveErr)
            Start-Sleep -Seconds 2
        }
    }
}

if (-not $saved) {
    Write-Host ''
    Fail ('설정 파일을 저장하지 못했습니다: ' + $saveErr)
    Say ''
    Say '  아래를 확인하고 bat 을 다시 실행하세요.'
    Say '   1) 열려 있는 클로드 코드 창을 모두 닫기 (/exit)'
    Say '   2) 이 설정 창을 두 개 이상 동시에 켜지 않기'
    Say '   3) 백신이 파일 쓰기를 막고 있지 않은지 확인'
    Say ('   4) 그래도 안 되면 이 기록 파일을 담당 교수에게 보내기')
    Say ('      ' + $LogPath)
    Stop-Here '설정 파일 저장 실패'
}
Step '저장'
Ok $path

# ================================================================ 연결 테스트
Title '연결 테스트'
Say '  키가 실제로 통하는지 확인합니다. (크레딧을 1토큰 정도만 씁니다)'

$body    = @{ model = $model; max_tokens = 1; messages = @(@{ role = 'user'; content = 'hi' }) } | ConvertTo-Json -Depth 5
$uri     = $baseUrl.TrimEnd('/') + '/v1/messages'
$testOk  = $false
$lastErr = ''

foreach ($mode in @('bearer', 'apikey')) {
    $h = @{ 'anthropic-version' = '2023-06-01'; 'content-type' = 'application/json' }
    if ($mode -eq 'bearer') { $h['Authorization'] = 'Bearer ' + $key }
    else { $h['x-api-key'] = $key }

    # 수업 시간에 여러 명이 동시에 실행하면 잠깐 몰려서 실패할 수 있으므로 몇 번 더 두드려 봄
    for ($cTry = 1; $cTry -le 3; $cTry++) {
        try {
            Invoke-RestMethod -Uri $uri -Method Post -Headers $h -Body $body -TimeoutSec 40 | Out-Null
            $testOk = $true
            break
        } catch {
            $code = $null
            try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch {}
            if ($code) { $lastErr = 'HTTP ' + $code } else { $lastErr = $_.Exception.Message }
            # 키가 틀렸거나 주소가 틀린 것은 다시 해도 같으므로 바로 넘어감
            if ($code -eq 400 -or $code -eq 401 -or $code -eq 403 -or $code -eq 404) { break }
            if ($cTry -lt 3) {
                Say ('    응답이 없거나 몰린 것 같습니다 (' + $lastErr + '). 5초 뒤 다시 시도합니다 (' + $cTry + '/3)')
                Start-Sleep -Seconds 5
            }
        }
    }
    if ($testOk) { break }
}

Step '응답'
if ($testOk) {
    Ok '정상 - 키가 살아 있습니다'
} else {
    Warn ('테스트 실패 (' + $lastErr + ')')
    if ($lastErr -match '401|403') {
        Say '      -> 키가 잘못됐거나 해지된 키입니다. 팩트챗에서 새 키를 발급받아 .env 에 다시 넣으세요.'
    } elseif ($lastErr -match '404') {
        Say '      -> 접속 주소가 다를 수 있습니다. .env 의 ANTHROPIC_BASE_URL 을 확인하세요.'
    } elseif ($lastErr -match '429') {
        Say '      -> 크레딧이 모두 소진되었거나 호출이 몰렸습니다.'
    } else {
        Say '      -> 설정 저장은 끝났습니다. 아래 안내대로 claude 를 직접 실행해 보세요.'
    }
}

# ================================================================ 마무리
Write-Host ''
if ($testOk) { $c = 'Green'; $msg = '   설정 완료 - 바로 쓸 수 있습니다' }
else { $c = 'Yellow'; $msg = '   설정은 저장됨 - 연결 테스트는 실패' }
Write-Host '==========================================' -ForegroundColor $c
Write-Host $msg -ForegroundColor $c
Write-Host '==========================================' -ForegroundColor $c
if ($nodeVer) { Say ('  노드JS    : ' + $nodeVer) } else { Say '  노드JS    : 확인 안 됨' }
if ($gitVer)  { Say ('  깃        : ' + $gitVer) }  else { Say '  깃        : 확인 안 됨' }
if ($pyVer)   { Say ('  파이썬    : ' + $pyVer) }   else { Say '  파이썬    : 확인 안 됨' }
Say ('  설정 파일 : ' + $path)
Say ('  모델      : ' + $model)
Say ('  키        : ' + (Mask-Key $key))
Say ('  실행 기록 : ' + $LogPath)
Say ''
Say '  이제 PowerShell 을 새로 열고 claude 를 실행하세요.'
Say '  로그인 화면 없이 곧바로 입력창이 열리면 성공입니다.'
Say '  종료는 /exit 또는 Ctrl+C 입니다.'
Say ''

try { Stop-Transcript | Out-Null } catch {}

if (Yes '지금 바로 클로드 코드를 실행할까요?') {
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $psExe)) { $psExe = 'powershell.exe' }
    $cmd = '"& ' + [char]39 + $ClaudeExe + [char]39 + '"'
    try {
        Start-Process -FilePath $psExe -ArgumentList '-NoExit', '-Command', $cmd -WorkingDirectory $ScriptDir
        Ok ('새 PowerShell 창에서 실행했습니다 (작업 폴더: ' + $ScriptDir + ')')
    } catch {
        Warn ('실행 실패: ' + $_.Exception.Message)
        Say '  PowerShell 을 새로 열고 claude 를 직접 입력하세요.'
    }
}
