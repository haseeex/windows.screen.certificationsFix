<#
.SYNOPSIS
    给 Windows 显示器补写认证标签（HDR / FreeSync 等）

.DESCRIPTION
    Windows「设置 → 显示 → HDR 认证」读的是注册表里的 DisplayHdrLevel（REG_MULTI_SZ）。
    这个值只有厂商 INF 才会写入，用系统自带 monitor.inf 的显示器会显示「未找到」。
    很多厂商的 INF 写得敷衍——只写一条泛称，不写杜比视界、也不写具体 DisplayHDR 等级。
    本脚本帮你自动定位显示器并追加认证标签。

    虽然这个注册表值名叫 DisplayHdrLevel，但它实际是个「认证标签列表」，
    除了 HDR 相关，还能承载其他显示认证：

        VESA DisplayHDR ......... 400 / 500 / 600 / 1000 / 1400 / 2000
        VESA DisplayHDR True Black  400TB / 500TB / 600TB / 1000TB（OLED 用）
        DisplayHDR 1.0 旧版规范 ... 400 / 600 / 1000 / 1400（一般不用）
        Dolby Vision 杜比视界
        AMD FreeSync with HDR .... 旧名（FreeSync 2 HDR 时代）
        AMD FreeSync Premium Pro . 新名（2020 年后）
        G-SYNC ULTIMATE ......... 需硬件模块，绝大多数显示器没有，慎用

    HDR 相关用 -Level / -NoDolby 参数指定；
    FreeSync、G-SYNC、旧版 1.0 规范等请用 -Menu 交互菜单勾选（命令行没有对应参数）。

    注意：这些标签只影响设置页显示的文字，不改变显示器实际能力。
    真正的自适应同步要在 NVIDIA 控制面板 → 显示 → 设置 G-SYNC 里开启。

    不支持：DisplayHDR 1.2 与 NVIDIA HDR（GUID 为微软内部定义，无法查到）。

    脚本会自动通过 Enum\DISPLAY\<厂商ID>\<实例>\Driver 找到对应的 Class 实例编号，
    所以换任何电脑、任何接入顺序都能正确定位，不会写错到别的显示器上。

.PARAMETER VendorId
    显示器厂商+产品码（如 XMI300A、DELA123），用 -List 查看本机实际值。
    不给则列出所有显示器让你选。

.PARAMETER Level
    DisplayHDR 等级：400 / 500 / 600 / 1000 / 1400 / 2000，
    或 400TB / 500TB / 600TB / 1000TB（True Black 系列）。
    不给则不加 DisplayHDR 等级，只加杜比视界。
    注意：本参数只处理 DisplayHDR 等级，FreeSync / G-SYNC 请用 -Menu。

.PARAMETER NoDolby
    不加杜比视界 GUID。

.PARAMETER Restore
    还原模式：把 DisplayHdrLevel 恢复成本次运行前的备份。

.PARAMETER List
    只列出所有显示器及其当前状态，不做任何修改。

.PARAMETER Menu
    交互菜单模式：↑↓ 移动、空格勾选、Enter 确认、Esc 取消。
    可勾选全部认证类型（含 FreeSync / G-SYNC），推荐普通用户使用。

.EXAMPLE
    .\Set-DisplayCertification.ps1 -List

.EXAMPLE
    .\Set-DisplayCertification.ps1 -VendorId XMI300A -Level 1000

.EXAMPLE
    .\Set-DisplayCertification.ps1 -VendorId XMI300A -Level 1000 -WhatIf

.EXAMPLE
    .\Set-DisplayCertification.ps1 -Menu
    打开交互菜单，可勾选 FreeSync Premium Pro 等命令行参数不支持的认证。

.NOTES
    必须以管理员身份运行（写 HKLM 需要提权）。
#>

# 注意：#requires 必须放在帮助块之后，否则 Get-Help 无法解析注释帮助
# （注释帮助只能被普通注释和空行前置，#requires 是特殊指令会干扰）
#requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$VendorId,
    [ValidateSet('', '400', '500', '600', '1000', '1400', '2000',
        '400TB', '500TB', '600TB', '1000TB')]
    [string]$Level = '',
    [switch]$NoDolby,
    [switch]$Restore,
    [switch]$List,
    [switch]$Menu
)

$ErrorActionPreference = 'Stop'
$ClassBase = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E96E-E325-11CE-BFC1-08002BE10318}'
$EnumBase = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'
$BackupDir = Join-Path $env:ProgramData 'DisplayHdrLevel-Backup'

# ============ GUID 对照表 ============
$GuidMap = [ordered]@{
    'VESA DisplayHDR (泛称)'      = 'E55026B6-496B-4ACC-B371-A1211D829ABD'
    'Dolby Vision 杜比视界'        = '6363AA90-A651-4154-A9E1-2D765C08E68F'
    'DisplayHDR 400 (1.0)'        = '20C5A9AF-CD1A-42B1-AA71-4C96A273DEF1'
    'DisplayHDR 400 (1.1)'        = '0D710BC2-6368-4EB2-A829-CBBD45CE3BD2'
    'DisplayHDR 400 TrueBlack (1.0)' = '1A6CBAFB-15FF-4CF0-AD75-12360E9B9F4A'
    'DisplayHDR 400 TrueBlack (1.1)' = 'FB4CB49B-F5A8-4084-800C-EB38E9CA16DE'
    'DisplayHDR 500 (1.1)'        = 'C47B4522-B803-47B0-831F-2ED63B56CE79'
    'DisplayHDR 500 TrueBlack (1.0)' = '86413F8C-0CDB-4D49-81F7-06BB64A8FED1'
    'DisplayHDR 500 TrueBlack (1.1)' = '3B6DAA9E-3794-4D85-897E-93AE990D275D'
    'DisplayHDR 600 (1.0)'        = 'D4C5928E-9488-46AF-8DA8-4F996EE4177F'
    'DisplayHDR 600 (1.1)'        = '7134A821-9254-4AF4-9973-95B3FCF720CC'
    'DisplayHDR 600 TrueBlack (1.1)' = '9AD0FB30-006E-49FE-AA15-8F65F28A476B'
    'DisplayHDR 1000 (1.0)'       = '78137DFC-3400-412E-B0AF-08120754623A'
    'DisplayHDR 1000 (1.1)'       = 'C624859D-304A-4DE8-86DC-8BE82B79527A'
    'DisplayHDR 1000 TrueBlack (1.1)' = '9C5D5F59-1FA8-4D2B-87DD-2E3B2BFF37D5'
    'DisplayHDR 1400 (1.0)'       = '670A25C9-E253-4AC9-A517-D97C8338C0D4'
    'DisplayHDR 1400 (1.1)'       = '3CA0903F-99E0-46FB-9BEC-DE023507BEF0'
    'DisplayHDR 2000 (1.1)'       = '80931144-16F1-4710-91F4-2E66713B134D'
    'G-SYNC ULTIMATE'             = '35FBD985-74F0-4271-AC61-295F11D71AEF'
    'AMD FreeSync with HDR'        = 'AE040E1F-51EC-4CAC-8501-E611C3C29CFE'
    'AMD FreeSync Premium Pro'     = 'F9310F0E-93B2-4A58-8642-17358D8CB2E3'
}

$DolbyGuid = '6363AA90-A651-4154-A9E1-2D765C08E68F'
$LevelGuidMap = @{
    '400'    = '0D710BC2-6368-4EB2-A829-CBBD45CE3BD2'
    '500'    = 'C47B4522-B803-47B0-831F-2ED63B56CE79'
    '600'    = '7134A821-9254-4AF4-9973-95B3FCF720CC'
    '1000'   = 'C624859D-304A-4DE8-86DC-8BE82B79527A'
    '1400'   = '3CA0903F-99E0-46FB-9BEC-DE023507BEF0'
    '2000'   = '80931144-16F1-4710-91F4-2E66713B134D'
    '400TB'  = 'FB4CB49B-F5A8-4084-800C-EB38E9CA16DE'
    '500TB'  = '3B6DAA9E-3794-4D85-897E-93AE990D275D'
    '600TB'  = '9AD0FB30-006E-49FE-AA15-8F65F28A476B'
    '1000TB' = '9C5D5F59-1FA8-4D2B-87DD-2E3B2BFF37D5'
}
# 同一等级的不同版本 GUID（用于去重时一并清除旧版）
$LevelFamilyMap = @{
    '400'    = @('20C5A9AF-CD1A-42B1-AA71-4C96A273DEF1', '0D710BC2-6368-4EB2-A829-CBBD45CE3BD2')
    '500'    = @('C47B4522-B803-47B0-831F-2ED63B56CE79')
    '600'    = @('D4C5928E-9488-46AF-8DA8-4F996EE4177F', '7134A821-9254-4AF4-9973-95B3FCF720CC')
    '1000'   = @('78137DFC-3400-412E-B0AF-08120754623A', 'C624859D-304A-4DE8-86DC-8BE82B79527A')
    '1400'   = @('670A25C9-E253-4AC9-A517-D97C8338C0D4', '3CA0903F-99E0-46FB-9BEC-DE023507BEF0')
    '2000'   = @('80931144-16F1-4710-91F4-2E66713B134D')
    '400TB'  = @('1A6CBAFB-15FF-4CF0-AD75-12360E9B9F4A', 'FB4CB49B-F5A8-4084-800C-EB38E9CA16DE')
    '500TB'  = @('86413F8C-0CDB-4D49-81F7-06BB64A8FED1', '3B6DAA9E-3794-4D85-897E-93AE990D275D')
    '600TB'  = @('9AD0FB30-006E-49FE-AA15-8F65F28A476B')
    '1000TB' = @('9C5D5F59-1FA8-4D2B-87DD-2E3B2BFF37D5')
}

# ============ 工具函数 ============
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Monitors {
    $result = @()
    if (-not (Test-Path $EnumBase)) { return $result }
    foreach ($vendor in (Get-ChildItem $EnumBase -ErrorAction SilentlyContinue)) {
        foreach ($inst in (Get-ChildItem $vendor.PSPath -ErrorAction SilentlyContinue)) {
            $drv = (Get-ItemProperty $inst.PSPath -Name Driver -ErrorAction SilentlyContinue).Driver
            if (-not $drv) { continue }
            $idx = if ($drv -match '(\d{4})$') { $matches[1] } else { $null }
            if (-not $idx) { continue }
            $clsPath = Join-Path $ClassBase $idx
            if (-not (Test-Path $clsPath)) { continue }
            $cv = Get-ItemProperty $clsPath -ErrorAction SilentlyContinue

            # 从 EDID 取显示器名称（描述符 0xFC）
            # 注意：Device Parameters 含空格，必须用字符串拼接而非 Join-Path 链式调用
            $name = ''
            try {
                $dpPath = $inst.PSPath + '\Device Parameters'
                $e = (Get-ItemProperty -Path $dpPath -Name EDID -ErrorAction Stop).EDID
                if ($e.Length -ge 128) {
                    $n = [int[]]$e
                    for ($k = 0; $k -lt 4; $k++) {
                        $o = 54 + $k * 18
                        if ($n[$o] -eq 0 -and $n[$o + 1] -eq 0 -and $n[$o + 2] -eq 0 -and $n[$o + 3] -eq 0xFC) {
                            $name = ([Text.Encoding]::ASCII.GetString($e, $o + 5, 13)).Trim([char]0, [char]10, [char]32)
                            break
                        }
                    }
                }
            } catch { }
            $result += [pscustomobject]@{
                VendorId    = $vendor.PSChildName
                Instance    = $inst.PSChildName
                ClassIndex  = $idx
                Name        = $name
                ICMProfile  = ($cv.ICMProfile -join ', ')
                MaxRes      = $cv.MaxResolution
                HdrLevel    = ($cv.DisplayHdrLevel -join ' | ')
            }
        }
    }
    return $result
}

function Resolve-GuidName([string]$g) {
    foreach ($k in $GuidMap.Keys) { if ($GuidMap[$k] -ieq $g) { return $k } }
    return '(未收录的 GUID)'
}

# 安全清屏：输出被重定向（如管道、日志）时 [Console] 无句柄，Clear-Host 会抛错
function Clear-Safe {
    try {
        if ([Console]::IsOutputRedirected) { return }
    } catch { return }
    try { Clear-Host } catch { }
}

# ==================================================================
#  TUI 引擎 —— 带边框 / 高亮 / 滚动 / 多选的终端界面
# ==================================================================

# ---------- ANSI 颜色 ----------
$script:ANSI = @{
    Reset   = "`e[0m"
    Bold    = "`e[1m"
    Dim     = "`e[2m"
    Reverse = "`e[7m"
    Cyan    = "`e[96m"
    Green   = "`e[92m"
    Yellow  = "`e[93m"
    Red     = "`e[91m"
    Gray    = "`e[90m"
    White   = "`e[97m"
    Magenta = "`e[95m"
    Blue    = "`e[94m"
    Black   = "`e[30m"
    # 按钮背景：选柔和配色，避免亮青底那种刺眼感
    BgGreen = "`e[42m`e[30m"      # 深绿底 + 黑字（主操作）
    BgGray  = "`e[100m`e[97m"     # 深灰底 + 亮白字（退路，比亮青柔和得多）
    BgCyan  = "`e[46m`e[30m"      # 保留：亮青底黑字（旧按钮样式，已不用）
}

# 开启 Windows 控制台的 VT 转义支持（Win10 1511+）
function Enable-AnsiSupport {
    try {
        if ([Console]::IsOutputRedirected) { return $false }
        if ($null -eq ('Win32.ConsoleVT' -as [type])) {
            Add-Type -Namespace Win32 -Name ConsoleVT -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction Stop
        }
        $h = [Win32.ConsoleVT]::GetStdHandle(-11)   # STD_OUTPUT_HANDLE
        $mode = [uint32]0
        if (-not [Win32.ConsoleVT]::GetConsoleMode($h, [ref]$mode)) { return $false }
        # ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
        if (-not [Win32.ConsoleVT]::SetConsoleMode($h, $mode -bor 0x0004)) { return $false }
        return $true
    } catch {
        return $false
    }
}

# 关闭颜色（ANSI 不可用时）
function Disable-Ansi {
    foreach ($k in @($script:ANSI.Keys)) { $script:ANSI[$k] = '' }
}

# 判断能否使用 TUI（需要有真实控制台）
function Test-TuiSupported {
    try {
        if ([Console]::IsOutputRedirected) { return $false }
        if ([Console]::IsInputRedirected) { return $false }
        $null = [Console]::WindowWidth
        $null = [Console]::WindowHeight
        $null = [Console]::CursorVisible
    } catch {
        return $false
    }
    return $true
}

# 单个字符的显示宽度（CJK / 全角占 2 列）
function Get-CharWidth([char]$Ch) {
    $c = [int]$Ch
    if (($c -ge 0x1100 -and $c -le 0x115F) -or
        ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
        ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
        ($c -ge 0xF900 -and $c -le 0xFAFF) -or
        ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
        ($c -ge 0xFF00 -and $c -le 0xFF60) -or
        ($c -ge 0xFFE0 -and $c -le 0xFFE6) -or
        ($c -ge 0x1F300 -and $c -le 0x1F9FF)) { return 2 }
    return 1
}

# 计算显示宽度（自动跳过 ANSI 转义序列）
function Get-DisplayWidth([string]$Text) {
    if (-not $Text) { return 0 }
    $w = 0
    $i = 0
    $len = $Text.Length
    while ($i -lt $len) {
        if ($Text[$i] -eq [char]27) {
            $i++
            if ($i -lt $len -and $Text[$i] -eq '[') {
                $i++
                while ($i -lt $len -and -not [char]::IsLetter($Text[$i])) { $i++ }
                $i++
            }
            continue
        }
        $w += Get-CharWidth $Text[$i]
        $i++
    }
    return $w
}

# 按显示宽度右侧补空格
function Pad-Display([string]$Text, [int]$Width) {
    if ($null -eq $Text) { $Text = '' }
    $dw = Get-DisplayWidth $Text
    if ($dw -ge $Width) { return $Text }
    return $Text + (' ' * ($Width - $dw))
}

# 按显示宽度截断（保留 ANSI 序列，末尾补 Reset）
function Trim-Display([string]$Text, [int]$Width) {
    if ($null -eq $Text) { return '' }
    if ((Get-DisplayWidth $Text) -le $Width) { return $Text }
    $sb = New-Object System.Text.StringBuilder
    $w = 0
    $i = 0
    $len = $Text.Length
    while ($i -lt $len) {
        if ($Text[$i] -eq [char]27) {
            $j = $i + 1
            if ($j -lt $len -and $Text[$j] -eq '[') {
                $j++
                while ($j -lt $len -and -not [char]::IsLetter($Text[$j])) { $j++ }
                $j++
                [void]$sb.Append($Text.Substring($i, $j - $i))
                $i = $j
                continue
            }
        }
        $cw = Get-CharWidth $Text[$i]
        if ($w + $cw -gt $Width - 1) { break }
        [void]$sb.Append($Text[$i])
        $w += $cw
        $i++
    }
    [void]$sb.Append('…')
    [void]$sb.Append($script:ANSI.Reset)
    return $sb.ToString()
}

# ---------- 帧绘制（行级差异，避免闪烁）----------
$script:Tui = @{
    PrevLines = New-Object System.Collections.Generic.List[string]
    Inited    = $false
}

function Initialize-Tui {
    $script:Tui.PrevLines = New-Object System.Collections.Generic.List[string]
    $script:Tui.Inited = $true
    try { [Console]::CursorVisible = $false } catch { }
    try { [Console]::Clear() } catch { }
}

function Restore-Tui {
    try { [Console]::CursorVisible = $true } catch { }
    try { [Console]::ResetColor() } catch { }
    $script:Tui.Inited = $false
}

# 获取当前终端尺寸（带兜底）
function Get-TuiSize {
    $w = 80; $h = 25
    try { $w = [Console]::WindowWidth } catch { }
    try { $h = [Console]::WindowHeight } catch { }
    if ($w -lt 30) { $w = 80 }
    if ($h -lt 8) { $h = 25 }
    return @{ W = $w; H = $h }
}

function Write-TuiFrame {
    param([string[]]$Lines, [switch]$Force)

    $sz = Get-TuiSize
    $w = $sz.W
    $h = $sz.H
    $maxY = [Math]::Min($Lines.Count, $h - 1)

    # 先统一裁剪补齐，再比较
    $final = New-Object System.Collections.Generic.List[string]
    for ($y = 0; $y -lt $maxY; $y++) {
        $line = if ($null -ne $Lines[$y]) { $Lines[$y] } else { '' }
        $final.Add((Pad-Display (Trim-Display $line ($w - 1)) ($w - 1)))
    }

    for ($y = 0; $y -lt $final.Count; $y++) {
        $prev = if ($y -lt $script:Tui.PrevLines.Count) { $script:Tui.PrevLines[$y] } else { $null }
        if ($Force -or $prev -ne $final[$y]) {
            try {
                [Console]::SetCursorPosition(0, $y)
                Write-Host $final[$y] -NoNewline
            } catch { }
        }
    }

    # 清掉上一帧多出来的行
    for ($y = $final.Count; $y -lt $script:Tui.PrevLines.Count -and $y -lt $h - 1; $y++) {
        try {
            [Console]::SetCursorPosition(0, $y)
            Write-Host (' ' * ($w - 1)) -NoNewline
        } catch { }
    }

    $script:Tui.PrevLines.Clear()
    foreach ($l in $final) { $script:Tui.PrevLines.Add($l) }

    # 光标藏到屏幕外，避免闪烁
    try { [Console]::SetCursorPosition(0, [Math]::Max(0, $h - 1)) } catch { }
}

function Read-TuiKey {
    try { return [Console]::ReadKey($true) } catch { return $null }
}

# ---------- 边框绘制工具 ----------
$script:BoxW = 76

function Get-BoxWidth {
    $sz = Get-TuiSize
    return [Math]::Max(50, [Math]::Min($script:BoxW, $sz.W - 2))
}

function New-BoxTop([string]$Title, [string]$Right) {
    $a = $script:ANSI
    $bw = Get-BoxWidth
    $inner = $bw - 2
    $t = " $Title "
    $r = if ($Right) { " $Right " } else { '' }
    $fill = $inner - (Get-DisplayWidth $t) - (Get-DisplayWidth $r)
    if ($fill -lt 0) { $fill = 0 }
    return ($a.Cyan + '╔' + $t + ('═' * $fill) + $r + '╗' + $a.Reset)
}

function New-BoxMid {
    $a = $script:ANSI
    $bw = Get-BoxWidth
    return ($a.Cyan + '╠' + ('═' * ($bw - 2)) + '╣' + $a.Reset)
}

function New-BoxBot {
    $a = $script:ANSI
    $bw = Get-BoxWidth
    return ($a.Cyan + '╚' + ('═' * ($bw - 2)) + '╝' + $a.Reset)
}

# 画一行内容（自动补齐到边框内宽）
function New-BoxRow([string]$Content) {
    $a = $script:ANSI
    $bw = Get-BoxWidth
    $inner = $bw - 2
    $c = if ($null -ne $Content) { $Content } else { '' }
    return ($a.Cyan + '║' + $a.Reset + (Pad-Display $c $inner) + $a.Cyan + '║' + $a.Reset)
}

# 渲染一个 TUI 按钮（固定宽度，选中时填充背景色）
# 宽度固定为 11 显示列：选中 "▶ [ 写 入 ]" / 未选 "  [ 写 入 ]"，切换时不跳动
function Format-TuiButton {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [bool]$Active = $false,
        [string]$ActiveBg = ''
    )
    $a = $script:ANSI
    $bg = if ($ActiveBg) { $ActiveBg } else { $a.BgGreen }
    $body = '[ ' + $Text + ' ]'
    if ($Active) {
        # ▶ 用亮青且不继承背景色，避免被背景吞掉
        return ($a.Bold + $a.Cyan + '▶' + $a.Reset + ' ' + $bg + $a.Bold + $body + $a.Reset)
    }
    return ($a.Gray + '  ' + $body + $a.Reset)
}

# ---------- 通用：确认对话框 ----------
function Show-TuiConfirm {
    param(
        [string]$Title = '确认',
        [string[]]$Body = @(),
        [string]$OkText = '确 定',
        [string]$CancelText = '取 消',
        [switch]$DefaultCancel
    )

    $a = $script:ANSI
    $sel = if ($DefaultCancel) { 1 } else { 0 }

    while ($true) {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('')
        $lines.Add((New-BoxTop $Title ''))
        $lines.Add((New-BoxMid))
        foreach ($b in $Body) { $lines.Add((New-BoxRow ('  ' + $b))) }
        $lines.Add((New-BoxRow ''))
        $lines.Add((New-BoxMid))

        # 按钮行：方括号边框 + 选中填充背景，▶ 用亮青色独立于背景
        $btn0 = Format-TuiButton -Text $OkText -Active ($sel -eq 0) -ActiveBg $a.BgGreen
        $btn1 = Format-TuiButton -Text $CancelText -Active ($sel -eq 1) -ActiveBg $a.BgGray

        $gap = 6
        $btnLineW = (Get-DisplayWidth $btn0) + $gap + (Get-DisplayWidth $btn1)
        $boxInner = (Get-BoxWidth) - 2
        $leftPad = [Math]::Max(2, [int](($boxInner - $btnLineW) / 2))
        $lines.Add((New-BoxRow ((' ' * $leftPad) + $btn0 + (' ' * $gap) + $btn1)))
        $lines.Add((New-BoxRow ''))
        $lines.Add((New-BoxRow ('  ' + $a.Gray + '← → 切换    Enter 确认    Esc 取消' + $a.Reset)))
        $lines.Add((New-BoxBot))

        Write-TuiFrame -Lines $lines.ToArray()

        $k = Read-TuiKey
        if ($null -eq $k) { return $false }

        switch ($k.Key) {
            'LeftArrow'  { $sel = 0 }
            'RightArrow' { $sel = 1 }
            'Tab'        { $sel = 1 - $sel }
            'Enter'      { return ($sel -eq 0) }
            'Escape'     { return $false }
            'Y'          { return $true }
            'N'          { return $false }
        }
    }
}

function Invoke-ApplyGuids {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Monitor,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Guids
    )

    $clsPath = Join-Path $ClassBase $Monitor.ClassIndex
    $cur = @()
    if ($Monitor.HdrLevel) { $cur = @($Monitor.HdrLevel -split '\s*\|\s*' | Where-Object { $_ }) }

    Write-Host ''
    Write-Host ('目标：' + $Monitor.VendorId + '  Class\' + $Monitor.ClassIndex + '  ' + $Monitor.Name) -ForegroundColor White
    Write-Host '  修改前：'
    if ($cur.Count -eq 0) { Write-Host '    (无)' }
    else { $cur | ForEach-Object { Write-Host ('    ' + $_ + '   ' + (Resolve-GuidName $_)) } }
    Write-Host '  修改后：'
    if ($Guids.Count -eq 0) { Write-Host '    (空 —— 将删除该值，回到「未找到」状态)' -ForegroundColor Yellow }
    else { $Guids | ForEach-Object { Write-Host ('    ' + $_ + '   ' + (Resolve-GuidName $_)) -ForegroundColor Green } }

    # 备份
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backFile = Join-Path $BackupDir ('HdrLevel-' + $Monitor.ClassIndex + '-' + $stamp + '.json')
    [pscustomobject]@{
        Time       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        VendorId   = $Monitor.VendorId
        Instance   = $Monitor.Instance
        ClassIndex = $Monitor.ClassIndex
        Original   = $cur
    } | ConvertTo-Json | Set-Content -Path $backFile -Encoding UTF8
    Write-Host ('  备份：' + $backFile) -ForegroundColor DarkGray

    if (-not (Test-Admin)) {
        Write-Host '  ✗ 需要管理员权限，请以管理员身份重新运行。' -ForegroundColor Red
        return $false
    }

    if ($PSCmdlet.ShouldProcess(('Class\' + $Monitor.ClassIndex), '写入 DisplayHdrLevel')) {
        try {
            if ($Guids.Count -eq 0) {
                Remove-ItemProperty -Path $clsPath -Name DisplayHdrLevel -ErrorAction Stop
            } else {
                Set-ItemProperty -Path $clsPath -Name DisplayHdrLevel -Value ([string[]]$Guids) -Type MultiString -ErrorAction Stop
            }
            Write-Host '  ✓ 写入成功' -ForegroundColor Green
            return $true
        } catch {
            Write-Host ('  ✗ 写入失败：' + $_.Exception.Message) -ForegroundColor Red
            return $false
        }
    }
    return $false
}

# ============ 交互菜单 ============
# 菜单可选认证项目（编号 / 标签 / GUID / 所属家族，同家族互斥）
# 注意：Family 为空表示不参与互斥；泛称与具体等级可以共存
#       同一 Family 的不同版本（1.0 / 1.1）互斥，选一个会自动取消另一个
$MenuItems = @(
    [pscustomobject]@{ No = 0;  Label = 'VESA DisplayHDR (泛称)';        Guid = 'E55026B6-496B-4ACC-B371-A1211D829ABD'; Family = '';       Group = 'VESA 通用（不带等级）' }
    [pscustomobject]@{ No = 1;  Label = 'DisplayHDR 400';                 Guid = '0D710BC2-6368-4EB2-A829-CBBD45CE3BD2'; Family = '400';    Group = '标准版（LCD / Mini LED）' }
    [pscustomobject]@{ No = 2;  Label = 'DisplayHDR 500';                 Guid = 'C47B4522-B803-47B0-831F-2ED63B56CE79'; Family = '500';    Group = '标准版（LCD / Mini LED）' }
    [pscustomobject]@{ No = 3;  Label = 'DisplayHDR 600';                 Guid = '7134A821-9254-4AF4-9973-95B3FCF720CC'; Family = '600';    Group = '标准版（LCD / Mini LED）' }
    [pscustomobject]@{ No = 4;  Label = 'DisplayHDR 1000';                Guid = 'C624859D-304A-4DE8-86DC-8BE82B79527A'; Family = '1000';   Group = '标准版（LCD / Mini LED）' }
    [pscustomobject]@{ No = 5;  Label = 'DisplayHDR 1400';                Guid = '3CA0903F-99E0-46FB-9BEC-DE023507BEF0'; Family = '1400';   Group = '标准版（LCD / Mini LED）' }
    [pscustomobject]@{ No = 6;  Label = 'DisplayHDR 2000';                Guid = '80931144-16F1-4710-91F4-2E66713B134D'; Family = '2000';   Group = '标准版（LCD / Mini LED）' }
    [pscustomobject]@{ No = 7;  Label = 'DisplayHDR 400 True Black';      Guid = 'FB4CB49B-F5A8-4084-800C-EB38E9CA16DE'; Family = '400TB';  Group = 'True Black（OLED）' }
    [pscustomobject]@{ No = 8;  Label = 'DisplayHDR 500 True Black';      Guid = '3B6DAA9E-3794-4D85-897E-93AE990D275D'; Family = '500TB';  Group = 'True Black（OLED）' }
    [pscustomobject]@{ No = 9;  Label = 'DisplayHDR 600 True Black';      Guid = '9AD0FB30-006E-49FE-AA15-8F65F28A476B'; Family = '600TB';  Group = 'True Black（OLED）' }
    [pscustomobject]@{ No = 10; Label = 'DisplayHDR 1000 True Black';     Guid = '9C5D5F59-1FA8-4D2B-87DD-2E3B2BFF37D5'; Family = '1000TB'; Group = 'True Black（OLED）' }
    [pscustomobject]@{ No = 11; Label = 'DisplayHDR 400 (1.0)';           Guid = '20C5A9AF-CD1A-42B1-AA71-4C96A273DEF1'; Family = '400';    Group = '旧版规范 1.0（一般不用）' }
    [pscustomobject]@{ No = 12; Label = 'DisplayHDR 600 (1.0)';           Guid = 'D4C5928E-9488-46AF-8DA8-4F996EE4177F'; Family = '600';    Group = '旧版规范 1.0（一般不用）' }
    [pscustomobject]@{ No = 13; Label = 'DisplayHDR 1000 (1.0)';          Guid = '78137DFC-3400-412E-B0AF-08120754623A'; Family = '1000';   Group = '旧版规范 1.0（一般不用）' }
    [pscustomobject]@{ No = 14; Label = 'DisplayHDR 1400 (1.0)';          Guid = '670A25C9-E253-4AC9-A517-D97C8338C0D4'; Family = '1400';   Group = '旧版规范 1.0（一般不用）' }
    [pscustomobject]@{ No = 15; Label = 'DisplayHDR 400 True Black (1.0)'; Guid = '1A6CBAFB-15FF-4CF0-AD75-12360E9B9F4A'; Family = '400TB'; Group = '旧版规范 1.0（一般不用）' }
    [pscustomobject]@{ No = 16; Label = 'DisplayHDR 500 True Black (1.0)'; Guid = '86413F8C-0CDB-4D49-81F7-06BB64A8FED1'; Family = '500TB'; Group = '旧版规范 1.0（一般不用）' }
    [pscustomobject]@{ No = 17; Label = 'Dolby Vision 杜比视界';          Guid = '6363AA90-A651-4154-A9E1-2D765C08E68F'; Family = '';       Group = '其他' }
    [pscustomobject]@{ No = 18; Label = 'G-SYNC ULTIMATE';                Guid = '35FBD985-74F0-4271-AC61-295F11D71AEF'; Family = '';       Group = '其他' }
    [pscustomobject]@{ No = 19; Label = 'AMD FreeSync with HDR';          Guid = 'AE040E1F-51EC-4CAC-8501-E611C3C29CFE'; Family = '';       Group = '其他' }
    [pscustomobject]@{ No = 20; Label = 'AMD FreeSync Premium Pro';       Guid = 'F9310F0E-93B2-4A58-8642-17358D8CB2E3'; Family = '';       Group = '其他' }
)

function Select-Certifications {
    param([pscustomobject]$Monitor)

    $a = $script:ANSI
    $cur = @()
    if ($Monitor.HdrLevel) { $cur = @($Monitor.HdrLevel -split '\s*\|\s*' | Where-Object { $_ }) }

    # 构建渲染行：分组标题前插入空行，视觉更清晰
    $render = New-Object System.Collections.Generic.List[object]
    $lastGroup = ''
    foreach ($it in $MenuItems) {
        if ($it.Group -ne $lastGroup) {
            if ($render.Count -gt 0) { $render.Add([pscustomobject]@{ Kind = 'Blank'; Text = ''; Item = $null }) }
            $render.Add([pscustomobject]@{ Kind = 'Group'; Text = $it.Group; Item = $null })
            $lastGroup = $it.Group
        }
        $render.Add([pscustomobject]@{ Kind = 'Item'; Text = $it.Label; Item = $it })
    }

    # 可选项在渲染行中的位置
    $itemRows = @()
    for ($i = 0; $i -lt $render.Count; $i++) {
        if ($render[$i].Kind -eq 'Item') { $itemRows += $i }
    }
    if ($itemRows.Count -eq 0) { return $null }

    # 勾选状态（初始 = 当前已有的）
    $checked = @{}
    foreach ($ri in $itemRows) {
        $checked[$ri] = [bool]($cur -contains $render[$ri].Item.Guid)
    }

    $pos = 0        # 在 $itemRows 中的位置
    $scroll = 0     # 渲染行滚动偏移
    $msg = ''
    $monName = if ($Monitor.Name) { $Monitor.Name } else { '(EDID 无名称)' }

    while ($true) {
        $sz = Get-TuiSize
        # 可见渲染行数：预留顶部 4 行 + 底部 5 行 + 滚动提示 1 行
        $visible = [Math]::Max(5, $sz.H - 10)

        # 确保光标项可见
        $curRow = $itemRows[$pos]
        if ($curRow -lt $scroll) { $scroll = $curRow }
        if ($curRow -ge $scroll + $visible) { $scroll = $curRow - $visible + 1 }
        if ($scroll -lt 0) { $scroll = 0 }
        $maxScroll = [Math]::Max(0, $render.Count - $visible)
        if ($scroll -gt $maxScroll) { $scroll = $maxScroll }

        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('')
        $lines.Add((New-BoxTop ($Monitor.VendorId + ' · ' + $monName) ('Class\' + $Monitor.ClassIndex)))
        $lines.Add((New-BoxMid))
        $lines.Add((New-BoxRow ''))

        if ($scroll -gt 0) {
            $lines.Add((New-BoxRow ('  ' + $a.Gray + '▲ 上方还有内容' + $a.Reset)))
        }

        $end = [Math]::Min($scroll + $visible, $render.Count)
        for ($r = $scroll; $r -lt $end; $r++) {
            $row = $render[$r]
            if ($row.Kind -eq 'Blank') {
                $lines.Add((New-BoxRow ''))
            } elseif ($row.Kind -eq 'Group') {
                $lines.Add((New-BoxRow ('  ' + $a.Magenta + $row.Text + $a.Reset)))
            } else {
                $mark = if ($checked[$r]) { $a.Green + '[✓]' + $a.Reset } else { $a.Gray + '[ ]' + $a.Reset }
                $label = $row.Item.Label
                if ($row.Item.Family -and $row.Item.Family -match 'TB$') {
                    $label = $label + '  ' + $a.Gray + '(仅限 OLED)' + $a.Reset
                }
                if ($r -eq $curRow) {
                    $lines.Add((New-BoxRow ('  ' + $a.Bold + $a.Cyan + '▶ ' + $a.Reset + $mark + ' ' + $a.Bold + $label + $a.Reset)))
                } else {
                    $lines.Add((New-BoxRow ('    ' + $mark + ' ' + $label)))
                }
            }
        }

        if ($end -lt $render.Count) {
            $lines.Add((New-BoxRow ('  ' + $a.Gray + '▼ 下方还有内容' + $a.Reset)))
        }

        $lines.Add((New-BoxRow ''))
        $lines.Add((New-BoxMid))

        $cnt = 0
        foreach ($ri in $itemRows) { if ($checked[$ri]) { $cnt++ } }
        $lines.Add((New-BoxRow ('  ' + $a.Gray + '↑↓ 移动   空格 勾选   C 清空   Enter 确认   Esc 取消' + $a.Reset)))
        $status = '  ' + $a.Yellow + '已选 ' + $cnt + ' 项' + $a.Reset
        if ($msg) { $status = $status + '    ' + $a.Red + $msg + $a.Reset }
        $lines.Add((New-BoxRow $status))
        $lines.Add((New-BoxBot))

        Write-TuiFrame -Lines $lines.ToArray()
        $msg = ''

        $k = Read-TuiKey
        if ($null -eq $k) { return $null }

        switch ($k.Key) {
            'UpArrow' { if ($pos -gt 0) { $pos-- } }
            'DownArrow' { if ($pos -lt $itemRows.Count - 1) { $pos++ } }
            'Home' { $pos = 0 }
            'End' { $pos = $itemRows.Count - 1 }
            'PageUp' { $pos = [Math]::Max(0, $pos - $visible) }
            'PageDown' { $pos = [Math]::Min($itemRows.Count - 1, $pos + $visible) }
            'Spacebar' {
                $ri = $itemRows[$pos]
                $checked[$ri] = -not $checked[$ri]

                # 同家族互斥：勾选某个等级时，自动取消同家族的其它版本
                if ($checked[$ri]) {
                    $fam = $render[$ri].Item.Family
                    if ($fam) {
                        $family = $LevelFamilyMap[$fam]
                        foreach ($x in $itemRows) {
                            if ($x -eq $ri) { continue }
                            if ($family -contains $render[$x].Item.Guid) { $checked[$x] = $false }
                        }
                    }
                }
            }
            'C' {
                foreach ($ri in $itemRows) { $checked[$ri] = $false }
                $msg = '已清空全部勾选'
            }
            'Enter' {
                $result = New-Object System.Collections.Generic.List[string]
                $menuGuids = @($MenuItems | ForEach-Object { $_.Guid })

                # 1. 先保留所有「当前已有、但不在菜单里」的 GUID
                #    防止未收录的 GUID（厂商私有等）被静默丢弃
                foreach ($g in $cur) {
                    if ($menuGuids -notcontains $g) { $result.Add($g) }
                }

                # 2. 再加上勾选的（去重）
                foreach ($ri in $itemRows) {
                    if ($checked[$ri]) {
                        $g = $render[$ri].Item.Guid
                        if (-not ($result -contains $g)) { $result.Add($g) }
                    }
                }
                return $result.ToArray()
            }
            'Escape' { return $null }
        }
    }
}

function Invoke-RestoreMenu {
    $a = $script:ANSI

    if (-not (Test-Path $BackupDir)) {
        Show-TuiMessage -Title '从备份还原' -Body @(
            '',
            ($a.Red + '找不到备份目录，没有可还原的记录。' + $a.Reset),
            '',
            ($a.Gray + $BackupDir + $a.Reset)
        )
        return
    }
    $backs = @(Get-ChildItem $BackupDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($backs.Count -eq 0) {
        Show-TuiMessage -Title '从备份还原' -Body @(
            '',
            ($a.Red + '备份目录里没有记录。' + $a.Reset),
            '',
            ($a.Gray + $BackupDir + $a.Reset)
        )
        return
    }

    # 预读所有记录
    $records = @()
    foreach ($b in $backs) {
        try {
            $j = Get-Content $b.FullName -Raw | ConvertFrom-Json
            $orig = if ($j.Original -and $j.Original.Count -gt 0) { ($j.Original -join ' | ') } else { '(原本为空)' }
            $records += [pscustomobject]@{
                Time       = $j.Time
                ClassIndex = $j.ClassIndex
                VendorId   = $j.VendorId
                Original   = $j.Original
                OrigText   = $orig
            }
        } catch { }
    }
    if ($records.Count -eq 0) {
        Show-TuiMessage -Title '从备份还原' -Body @('', ($a.Red + '所有备份记录都无法解析。' + $a.Reset))
        return
    }

    $pos = 0
    $scroll = 0

    while ($true) {
        $sz = Get-TuiSize
        $visible = [Math]::Max(2, [int](($sz.H - 8) / 3))

        if ($pos -lt $scroll) { $scroll = $pos }
        if ($pos -ge $scroll + $visible) { $scroll = $pos - $visible + 1 }
        if ($scroll -lt 0) { $scroll = 0 }

        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('')
        $lines.Add((New-BoxTop '从备份还原' ($records.Count.ToString() + ' 条记录')))
        $lines.Add((New-BoxMid))
        $lines.Add((New-BoxRow ''))

        if ($scroll -gt 0) {
            $lines.Add((New-BoxRow ('  ' + $a.Gray + '▲ 上方还有 ' + $scroll + ' 条' + $a.Reset)))
        }

        $end = [Math]::Min($scroll + $visible, $records.Count)
        for ($i = $scroll; $i -lt $end; $i++) {
            $r = $records[$i]
            $head = $r.Time + '    Class\' + $r.ClassIndex + '    ' + $r.VendorId
            if ($i -eq $pos) {
                $lines.Add((New-BoxRow ('  ' + $a.Bold + $a.Cyan + '▶ ' + $head + $a.Reset)))
            } else {
                $lines.Add((New-BoxRow ('    ' + $head)))
            }
            $lines.Add((New-BoxRow ('      ' + $a.Gray + '原值：' + $r.OrigText + $a.Reset)))
        }

        if ($end -lt $records.Count) {
            $lines.Add((New-BoxRow ('  ' + $a.Gray + '▼ 下方还有 ' + ($records.Count - $end) + ' 条' + $a.Reset)))
        }

        $lines.Add((New-BoxRow ''))
        $lines.Add((New-BoxMid))
        $lines.Add((New-BoxRow ('  ' + $a.Gray + '↑↓ 选择   Enter 还原   Esc 取消' + $a.Reset)))
        $lines.Add((New-BoxBot))

        Write-TuiFrame -Lines $lines.ToArray()

        $k = Read-TuiKey
        if ($null -eq $k) { return }

        switch ($k.Key) {
            'UpArrow' { if ($pos -gt 0) { $pos-- } }
            'DownArrow' { if ($pos -lt $records.Count - 1) { $pos++ } }
            'Home' { $pos = 0 }
            'End' { $pos = $records.Count - 1 }
            'Escape' { return }
            'Enter' {
                $pick = $records[$pos]
                $clsPath = Join-Path $ClassBase $pick.ClassIndex

                if (-not (Test-Admin)) {
                    Show-TuiMessage -Title '权限不足' -Body @(
                        '',
                        ($a.Red + '还原需要管理员权限。' + $a.Reset),
                        '',
                        ($a.Gray + '请右键 运行.bat → 以管理员身份运行' + $a.Reset)
                    )
                    return
                }

                $ok = Show-TuiConfirm -Title '确认还原' -Body @(
                    ('目标：' + $pick.VendorId + '  Class\' + $pick.ClassIndex),
                    ('备份时间：' + $pick.Time),
                    '',
                    ('将恢复为：' + $pick.OrigText)
                ) -OkText '还 原' -CancelText '取 消'

                if (-not $ok) { continue }

                try {
                    if ($pick.Original -and $pick.Original.Count -gt 0) {
                        Set-ItemProperty -Path $clsPath -Name DisplayHdrLevel -Value ([string[]]$pick.Original) -Type MultiString -ErrorAction Stop
                        $msg = '✓ 已还原为：' + ($pick.Original -join ' | ')
                    } else {
                        Remove-ItemProperty -Path $clsPath -Name DisplayHdrLevel -ErrorAction SilentlyContinue
                        $msg = '✓ 已删除 DisplayHdrLevel（回到「未找到」状态）'
                    }
                    Show-TuiMessage -Title '还原成功' -Body @(
                        '',
                        ($a.Green + $msg + $a.Reset),
                        '',
                        ($a.Yellow + '⚠ 需要重启电脑才会在设置页生效。' + $a.Reset)
                    )
                } catch {
                    Show-TuiMessage -Title '还原失败' -Body @('', ($a.Red + $_.Exception.Message + $a.Reset))
                }
                return
            }
        }
    }
}

# 通用消息框（按任意键关闭）
function Show-TuiMessage {
    param(
        [string]$Title = '提示',
        [string[]]$Body = @()
    )
    $a = $script:ANSI
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('')
    $lines.Add((New-BoxTop $Title ''))
    $lines.Add((New-BoxMid))
    foreach ($b in $Body) { $lines.Add((New-BoxRow ('  ' + $b))) }
    $lines.Add((New-BoxRow ''))
    $lines.Add((New-BoxMid))
    $lines.Add((New-BoxRow ('  ' + $a.Gray + '按任意键继续' + $a.Reset)))
    $lines.Add((New-BoxBot))

    Write-TuiFrame -Lines $lines.ToArray() -Force
    $null = Read-TuiKey
}

function Show-InteractiveMenu {
    param([object[]]$Monitors)

    $a = $script:ANSI
    $isAdmin = Test-Admin
    $pos = 0
    $scroll = 0
    $msg = ''

    # 动态计算厂商 ID 的列宽（避免 Default_Monitor 这类长 ID 破坏对齐）
    $vendorW = 13
    foreach ($mm in $Monitors) {
        if ($mm.VendorId.Length -gt $vendorW) { $vendorW = $mm.VendorId.Length }
    }

    while ($true) {
        $sz = Get-TuiSize
        $visible = [Math]::Max(2, [int](($sz.H - 9) / 3))

        if ($pos -lt $scroll) { $scroll = $pos }
        if ($pos -ge $scroll + $visible) { $scroll = $pos - $visible + 1 }
        if ($scroll -lt 0) { $scroll = 0 }

        $rightTag = if ($isAdmin) { $a.Green + '[管理员] ✓' + $a.Reset } else { $a.Yellow + '[普通用户]' + $a.Reset }

        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('')
        $lines.Add((New-BoxTop 'Windows 屏幕认证修复工具' $rightTag))
        $lines.Add((New-BoxMid))
        $lines.Add((New-BoxRow ''))

        if ($scroll -gt 0) {
            $lines.Add((New-BoxRow ('  ' + $a.Gray + '▲ 上方还有 ' + $scroll + ' 台' + $a.Reset)))
        }

        $end = [Math]::Min($scroll + $visible, $Monitors.Count)
        for ($i = $scroll; $i -lt $end; $i++) {
            $m = $Monitors[$i]
            $nm = if ($m.Name) { $m.Name } else { '(EDID 无名称)' }
            $head = $m.VendorId.PadRight($vendorW + 2) + $nm
            $tail = 'Class\' + $m.ClassIndex

            if ($i -eq $pos) {
                $lines.Add((New-BoxRow ('  ' + $a.Bold + $a.Cyan + '▶ ' + $head + $a.Reset + '   ' + $a.Gray + $tail + $a.Reset)))
            } else {
                $lines.Add((New-BoxRow ('    ' + $head + '   ' + $a.Gray + $tail + $a.Reset)))
            }

            if ($m.HdrLevel) {
                $gs = $m.HdrLevel -split '\s*\|\s*'
                $ns = ($gs | ForEach-Object { Resolve-GuidName $_ }) -join ' · '
                $lines.Add((New-BoxRow ('      ' + $a.Green + $ns + $a.Reset)))
            } else {
                $lines.Add((New-BoxRow ('      ' + $a.Gray + '(无 HDR 认证)' + $a.Reset)))
            }
        }

        if ($end -lt $Monitors.Count) {
            $lines.Add((New-BoxRow ('  ' + $a.Gray + '▼ 下方还有 ' + ($Monitors.Count - $end) + ' 台' + $a.Reset)))
        }

        $lines.Add((New-BoxRow ''))
        $lines.Add((New-BoxMid))
        $lines.Add((New-BoxRow ('  ' + $a.Gray + '↑↓ 选择    Enter 修改认证    R 从备份还原    Q 退出' + $a.Reset)))
        if ($msg) {
            $lines.Add((New-BoxRow ('  ' + $msg)))
        } else {
            $lines.Add((New-BoxRow ('  ' + $a.Gray + '提示：本工具只改显示标签，不改变显示器实际能力' + $a.Reset)))
        }
        $lines.Add((New-BoxBot))

        Write-TuiFrame -Lines $lines.ToArray()
        $msg = ''

        $k = Read-TuiKey
        if ($null -eq $k) { return }

        switch ($k.Key) {
            'UpArrow' { if ($pos -gt 0) { $pos-- } }
            'DownArrow' { if ($pos -lt $Monitors.Count - 1) { $pos++ } }
            'Home' { $pos = 0 }
            'End' { $pos = $Monitors.Count - 1 }
            'PageUp' { $pos = [Math]::Max(0, $pos - $visible) }
            'PageDown' { $pos = [Math]::Min($Monitors.Count - 1, $pos + $visible) }
            'R' { Invoke-RestoreMenu }
            'Q' { return }
            'Escape' { return }
            'Enter' {
                $m = $Monitors[$pos]
                $chosen = Select-Certifications -Monitor $m
                if ($null -eq $chosen) { continue }

                # 组装确认框内容
                $cur = @()
                if ($m.HdrLevel) { $cur = @($m.HdrLevel -split '\s*\|\s*' | Where-Object { $_ }) }
                $nm = if ($m.Name) { $m.Name } else { '(无名称)' }

                $body = New-Object System.Collections.Generic.List[string]
                $body.Add('目标：' + $m.VendorId + '  ' + $nm + '  Class\' + $m.ClassIndex)
                $body.Add('')
                $body.Add('修改前（' + $cur.Count + ' 项）：')
                if ($cur.Count -eq 0) { $body.Add('  ' + $a.Gray + '(无)' + $a.Reset) }
                else { foreach ($g in $cur) { $body.Add('  · ' + (Resolve-GuidName $g)) } }
                $body.Add('')
                $body.Add('修改后（' + $chosen.Count + ' 项）：')
                if ($chosen.Count -eq 0) {
                    $body.Add('  ' + $a.Yellow + '(空 —— 将删除该值，回到「未找到」状态)' + $a.Reset)
                } else {
                    foreach ($g in $chosen) { $body.Add('  ' + $a.Green + '· ' + (Resolve-GuidName $g) + $a.Reset) }
                }

                $ok = Show-TuiConfirm -Title '确认写入' -Body $body.ToArray() -OkText '写 入' -CancelText '取 消'
                if (-not $ok) { continue }

                $succeeded = Invoke-ApplyGuids -Monitor $m -Guids $chosen

                if ($succeeded) {
                    Show-TuiMessage -Title '写入成功' -Body @(
                        '',
                        ($a.Green + '✓ 已写入 ' + $chosen.Count + ' 项认证' + $a.Reset),
                        '',
                        ($a.Yellow + '⚠ 需要重启电脑（或注销重新登录）才会在设置页生效。' + $a.Reset)
                    )
                    # 刷新显示器列表
                    $Monitors = @(Get-Monitors)
                } else {
                    Show-TuiMessage -Title '写入失败' -Body @(
                        '',
                        ($a.Red + '✗ 写入未完成' + $a.Reset),
                        '',
                        ($a.Gray + '常见原因：没有管理员权限。' + $a.Reset),
                        ($a.Gray + '请右键 运行.bat → 以管理员身份运行' + $a.Reset)
                    )
                }
            }
        }
    }
}

# 降级：无 TUI 环境（输出被重定向等）时的纯文本菜单
function Show-PlainMenu {
    param([object[]]$Monitors)

    while ($true) {
        Clear-Safe
        Write-Host ''
        Write-Host '=== Windows 屏幕认证修复工具 ===' -ForegroundColor Cyan
        Write-Host ''
        if (Test-Admin) { Write-Host '  权限：管理员 ✓' -ForegroundColor Green }
        else { Write-Host '  权限：普通用户（无法写入）' -ForegroundColor Yellow }
        Write-Host ''
        Write-Host ('  检测到 ' + $Monitors.Count + ' 个显示器：') -ForegroundColor Yellow
        $i = 0
        foreach ($m in $Monitors) {
            $i++
            $nm = if ($m.Name) { $m.Name } else { '(EDID 无名称)' }
            Write-Host ('    [' + $i + '] ' + $m.VendorId.PadRight(14) + $nm + '   Class\' + $m.ClassIndex)
        }
        Write-Host ''
        Write-Host '  输入显示器编号修改，R 还原，回车退出' -ForegroundColor DarkGray
        Write-Host ''
        $sel = Read-Host '  请选择'
        if (-not $sel -or $sel -match '^[Qq]$') { return }
        if ($sel -match '^[Rr]$') { Invoke-RestoreMenu; continue }
        $n = 0
        if (-not [int]::TryParse($sel, [ref]$n) -or $n -lt 1 -or $n -gt $Monitors.Count) {
            Write-Host '  编号无效。' -ForegroundColor Red
            continue
        }
        $chosen = Select-Certifications -Monitor $Monitors[$n - 1]
        if ($null -eq $chosen) { continue }
        Invoke-ApplyGuids -Monitor $Monitors[$n - 1] -Guids $chosen | Out-Null
        $Monitors = @(Get-Monitors)
    }
}

# ============ 主流程 ============
Write-Host ''
Write-Host '=== Windows 屏幕认证修复工具 ===' -ForegroundColor Cyan
Write-Host ''

$monitors = @(Get-Monitors)
if ($monitors.Count -eq 0) {
    Write-Host '未找到任何显示器实例。' -ForegroundColor Red
    exit 1
}

# ---------- 交互菜单模式 ----------
if ($Menu) {
    if (-not (Test-TuiSupported)) {
        # 无真实控制台（重定向等）→ 退回纯文本菜单
        Disable-Ansi
        Show-PlainMenu -Monitors $monitors
        exit 0
    }

    # 开启 ANSI 颜色（失败则退化为无色）
    if (-not (Enable-AnsiSupport)) { Disable-Ansi }

    Initialize-Tui
    try {
        Show-InteractiveMenu -Monitors $monitors
    } finally {
        Restore-Tui
        try { [Console]::Clear() } catch { }
        Write-Host ''
        Write-Host '  已退出。' -ForegroundColor DarkGray
        Write-Host ''
    }
    exit 0
}

# ---------- 列表模式 ----------
if ($List -or (-not $VendorId -and -not $Restore)) {
    Write-Host ("检测到 " + $monitors.Count + " 个显示器实例：") -ForegroundColor Yellow
    Write-Host ''
    $i = 0
    foreach ($m in $monitors) {
        $i++
        Write-Host ("  [" + $i + "] " + $m.VendorId + "  ->  Class\" + $m.ClassIndex) -ForegroundColor White
        Write-Host ("      名称       : " + $(if ($m.Name) { $m.Name } else { '(EDID 无名称)' }))
        Write-Host ("      ICM        : " + $(if ($m.ICMProfile) { $m.ICMProfile } else { '(无)' }))
        Write-Host ("      最大分辨率 : " + $(if ($m.MaxRes) { $m.MaxRes } else { '(无)' }))
        if ($m.HdrLevel) {
            Write-Host ("      HDR 认证   : ") -NoNewline
            $guids = $m.HdrLevel -split '\s*\|\s*'
            $names = $guids | ForEach-Object { Resolve-GuidName $_ }
            Write-Host (($names -join ' + ')) -ForegroundColor Green
        } else {
            Write-Host ("      HDR 认证   : (无 —— 设置页会显示「未找到」)") -ForegroundColor DarkGray
        }
        Write-Host ''
    }
    if (-not $VendorId -and -not $Restore) {
        Write-Host '提示：用 -VendorId <厂商ID> 指定要修改的显示器，例如：' -ForegroundColor DarkGray
        Write-Host ('  ' + $MyInvocation.MyCommand.Name + ' -VendorId ' + $monitors[0].VendorId + ' -Level 1000') -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '可选等级 -Level：400 / 500 / 600 / 1000 / 1400 / 2000 / 400TB / 500TB / 600TB / 1000TB' -ForegroundColor DarkGray
        exit 0
    }
}

# ---------- 还原模式 ----------
if ($Restore) {
    if (-not (Test-Path $BackupDir)) {
        Write-Host ('找不到备份目录：' + $BackupDir) -ForegroundColor Red
        exit 1
    }
    $backs = @(Get-ChildItem $BackupDir -Filter '*.json' | Sort-Object LastWriteTime -Descending)
    if ($backs.Count -eq 0) {
        Write-Host '备份目录里没有记录。' -ForegroundColor Red
        exit 1
    }
    Write-Host '可用的备份记录：' -ForegroundColor Yellow
    $i = 0
    foreach ($b in $backs) {
        $i++
        $j = Get-Content $b.FullName -Raw | ConvertFrom-Json
        Write-Host ("  [" + $i + "] " + $b.Name + "   Class\" + $j.ClassIndex + "   " + $j.Time)
    }
    $sel = Read-Host '输入要还原的编号（直接回车取消）'
    if (-not $sel) { Write-Host '已取消。'; exit 0 }
    $pick = $backs[[int]$sel - 1]
    if (-not $pick) { Write-Host '编号无效。' -ForegroundColor Red; exit 1 }
    $j = Get-Content $pick.FullName -Raw | ConvertFrom-Json
    $clsPath = Join-Path $ClassBase $j.ClassIndex
    if (-not (Test-Admin)) { Write-Host '需要管理员权限。' -ForegroundColor Red; exit 1 }
    if ($PSCmdlet.ShouldProcess(('Class\' + $j.ClassIndex), '还原 DisplayHdrLevel')) {
        if ($j.Original -and $j.Original.Count -gt 0) {
            Set-ItemProperty -Path $clsPath -Name DisplayHdrLevel -Value ([string[]]$j.Original) -Type MultiString
            Write-Host ('已还原为：' + ($j.Original -join ' | ')) -ForegroundColor Green
        } else {
            Remove-ItemProperty -Path $clsPath -Name DisplayHdrLevel -ErrorAction SilentlyContinue
            Write-Host '已删除 DisplayHdrLevel（回到「未找到」状态）' -ForegroundColor Green
        }
    }
    exit 0
}

# ---------- 修改模式 ----------
$target = $monitors | Where-Object { $_.VendorId -ieq $VendorId }
if (-not $target) {
    Write-Host ('找不到厂商ID 为 "' + $VendorId + '" 的显示器。用 -List 查看可用列表。') -ForegroundColor Red
    exit 1
}
$target = @($target)
if ($target.Count -gt 1) {
    Write-Host ('厂商ID "' + $VendorId + '" 匹配到 ' + $target.Count + ' 个实例（同一显示器可能有多个连接记录）：') -ForegroundColor Yellow
    $target | ForEach-Object { Write-Host ('  Class\' + $_.ClassIndex + '   ' + $_.Instance) }
    Write-Host '将全部修改。' -ForegroundColor Yellow
}

# 计算要写入的 GUID 列表
foreach ($t in $target) {
    $cur = @()
    if ($t.HdrLevel) { $cur = @($t.HdrLevel -split '\s*\|\s*' | Where-Object { $_ }) }

    # 注意：变量名不能叫 $list —— 会与 -List 参数变量冲突（PowerShell 不区分大小写）
    $guidList = New-Object System.Collections.Generic.List[string]
    foreach ($x in $cur) { $guidList.Add($x) }

    # 1. 加杜比视界
    if (-not $NoDolby) {
        $has = $false
        foreach ($x in $guidList) { if ($x -ieq $DolbyGuid) { $has = $true; break } }
        if (-not $has) { $guidList.Add($DolbyGuid) }
    }

    # 2. 加 DisplayHDR 等级（先清掉同等级的旧版本，避免重复）
    if ($Level) {
        $newGuid = $LevelGuidMap[$Level]
        $family = $LevelFamilyMap[$Level]
        for ($i = $guidList.Count - 1; $i -ge 0; $i--) {
            if ($family -contains $guidList[$i]) { $guidList.RemoveAt($i) }
        }
        $guidList.Add($newGuid)
    }

    Invoke-ApplyGuids -Monitor $t -Guids $guidList.ToArray() | Out-Null
}

Write-Host ''
Write-Host '⚠ 需要重启电脑（或注销重新登录）才会在设置页生效。' -ForegroundColor Yellow
Write-Host '⚠ 本工具只改显示标签，不改变显示器的实际能力。' -ForegroundColor Yellow
Write-Host ('   回退：' + $MyInvocation.MyCommand.Name + ' -Restore') -ForegroundColor DarkGray
