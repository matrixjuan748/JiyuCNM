# Requires -RunAsAdministrator

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}
# 设置执行策略
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction SilentlyContinue

# 配置参数
$processNames = "*StudentMain*", "*capclient_c*", "*MasterHelper*", 
                "*veyon-server*", "*veyon-worker*", "*veyon-service*", 
                "*FSCapture*"
$firewallRuleName = "Block_FSCapture_Permanent"
$checkInterval = 30  # 30秒间隔
$FSCapturePath = "C:\Program Files (x86)\FastStone Capture\FSCapture.exe"
$shutdownPath = 'C:\Program Files (x86)\Mythware\极域课堂管理系统软件v6.0\Shutdown.exe'
$serviceNames = "tdnetfilter", "tdfilefilter"
$logPath = "C:\blocker_script.log"
$networkRetryCount = 3
$networkTimeout = 5

# 日志记录函数
function Write-Log {
    param ([string]$Message, [switch]$Error)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp $Message"
    if ($Error) {
        $logEntry = "ERROR: $logEntry"
    }
    $logEntry | Out-File -FilePath $logPath -Append
}

# 修正后的文件权限设置
try {
    & icacls `"$FSCapturePath`" /inheritance:r /deny:S-1-1-0:X 2>$null
    Write-Host "已永久禁用文件执行权限" -ForegroundColor Green
} catch {
    Write-Host "权限修改失败：$_" -ForegroundColor Red
}

# 修正后的防火墙规则初始化
try {
    $ruleName = "Block FSCapture"
    if (-not (Get-NetFirewallApplicationFilter -Program $FSCapturePath -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Direction Outbound `
            -Program $FSCapturePath `
            -Action Block `
            -Profile Any `
            -Enabled True | Out-Null
        Write-Host "已创建防火墙出站阻止规则" -ForegroundColor Green
    }
} catch {
    Write-Host "防火墙规则创建失败：$_" -ForegroundColor Red
}

function Get-ProcessTree {
    param([int]$ProcessId)
    Write-Log "正在获取进程树，根PID: $ProcessId"
    
    $allProcesses = @{}
    Get-CimInstance Win32_Process | ForEach-Object { 
        $allProcesses[$_.ProcessId] = $_ 
    }
    
    $tree = @($ProcessId)
    $visited = @{}
    
    while ($tree.Count -gt 0) {
        $current = $tree[0]
        $tree = $tree[1..($tree.Count-1)]
        
        if ($visited.ContainsKey($current)) { continue }
        $visited[$current] = $true
        
        $children = $allProcesses.Values | 
            Where-Object { $_.ParentProcessId -eq $current } | 
            Select-Object -ExpandProperty ProcessId
        
        $tree += $children
        if ($children) {
            Write-Log "发现子进程：父PID=$current, 子PIDs=$($children -join ',')"
        }
    }
    
    return $visited.Keys
}

function Stop-Processes {
    foreach ($name in $processNames) {
        try {
            $processes = Get-Process -Name $name -ErrorAction Stop
            if (-not $processes) {
                Write-Log "未找到进程：$name"
                continue
            }
            
            $processes | ForEach-Object {
                $treePids = Get-ProcessTree -ProcessId $_.Id
                if ($treePids.Count -eq 0) {
                    Write-Log "警告：未找到PID $($_.Id) 的子进程"
                }
                
                try {
                    Stop-Process -Id $treePids -Force -ErrorAction Stop
                    Write-Log "成功终止进程树：$name (PIDs: $($treePids -join ','))"
                } catch {
                    Write-Log "终止进程失败[PID $($_.Id)]：$_" -Error
                }
            }
            
            # 二次验证
            Start-Sleep -Seconds 1
            $remaining = Get-Process -Name $name -ErrorAction SilentlyContinue
            if ($remaining) {
                Write-Log "检测到残留进程 $name，尝试强制终止"
                $remaining | Stop-Process -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Log "获取进程 $name 失败：$_" -Error
        }
    }
}

# 重命名Shutdown程序
function Rename-ShutdownFile {
    if (Test-Path $shutdownPath) {
        $newName = if ($shutdownPath.EndsWith(".exe")) { 
            [System.IO.Path]::ChangeExtension($shutdownPath, ".exe.txt") 
        } else { 
            "$shutdownPath.txt" 
        }
        
        if (Test-Path $newName) {
            Remove-Item $newName -Force -ErrorAction SilentlyContinue
        }
        
        try {
            Rename-Item -LiteralPath $shutdownPath -NewName $newName -Force
            Write-Log "已重命名Shutdown程序：$shutdownPath -> $newName"
        } catch {
            Write-Log "重命名Shutdown程序失败：$_" -Error
        }
    }
}

# 停止系统服务
function Stop-SystemServices {
    foreach ($service in $serviceNames) {
        try {
            if ($svc = Get-Service $service -ErrorAction SilentlyContinue) {
                if ($svc.Status -ne 'Stopped') {
                    Stop-Service -Name $service -Force
                    Write-Log "已停止服务：$service"
                }
            }
        } catch {
            Write-Log "停止服务 $service 失败：$_" -Error
        }
    }
}

# 清理目标文件
function Clear-TargetFiles {
    try {
        $dateDir = Get-Date -Format "yyyy-MM-dd"
        $deviceName = $env:COMPUTERNAME
        $targetPath = "\\jf1-dell\capturescreen\$dateDir\$deviceName"
        
        # 网络路径访问（带重试）
        for ($i = 0; $i -lt $networkRetryCount; $i++) {
            try {
                Test-Path $targetPath | Out-Null
                break
            } catch {
                if ($i -eq $networkRetryCount - 1) { throw }
                Start-Sleep -Seconds $networkTimeout
            }
        }
        
        if (-not (Test-Path $targetPath)) {
            New-Item -Path $targetPath -ItemType Directory -Force | Out-Null
        }

        Get-ChildItem -Path $targetPath -File -Recurse | ForEach-Object {
            Set-Content -Path $_.FullName -Value $null -Force
        }
        Write-Log "已清空目录：$targetPath"
    } catch {
        Write-Log "文件清理失败：$_" -Error
    }
}

# 主监控循环
while ($true) {
    try {
        Stop-Processes
        Rename-ShutdownFile
        Stop-SystemServices
        Clear-TargetFiles
    } catch {
        Write-Log "主循环异常：$_" -Error
    }
    
    # 等待下次执行
    Start-Sleep -Seconds $checkInterval
}


# SIG # Begin signature block
# MIIFmgYJKoZIhvcNAQcCoIIFizCCBYcCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUz1yNNBgQJN+gdVUPKAB1Wkr4
# 6x+gggMmMIIDIjCCAgqgAwIBAgIQLyp1nLVk/oJLu4eggWVBxjANBgkqhkiG9w0B
# AQsFADApMScwJQYDVQQDDB5NYXRyaXggSHVhbmcgLSBDb2RlIFNpZ25pbmcgQ0Ew
# HhcNMjUwNTA5MDQyOTMyWhcNMjYwNTA5MDQ0OTMyWjApMScwJQYDVQQDDB5NYXRy
# aXggSHVhbmcgLSBDb2RlIFNpZ25pbmcgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDCRALn9/lIrKScsB1Oa7NqtrNncRpiwshTWCgtV0lRbJHdsQHg
# 6BwmhHmi52vjj1z6mRPE3lrij9DQQWkeY42ZmvnPuG+rQGKbVbAYpWaSgBQajLvl
# KAymDQfPM6/Kmb8+4VS6jI/ClNTelgjjwEhrZ/LIkcCwJYSh7WtNNuaAWTTlWy1c
# zT4k/Afd/V3TM6PFolde82VtSC4VjFtSIbLNmMy/OsefzB5jjihjcH0vJiZJv3Lx
# TawWg9b07UU86qWU+B2RP5DKd9J/yxp5NDrG7mMAWDFFMzNRGXZIvZZ4lraayG2/
# 6BsxYOJnr8H4spssHL7Lvt7q1OjMWJp/evE9AgMBAAGjRjBEMA4GA1UdDwEB/wQE
# AwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAzAdBgNVHQ4EFgQUApFkkCs3shTZ6h6a
# ERtNjtfb8ycwDQYJKoZIhvcNAQELBQADggEBAHbsu/eMCdi5yD1VjLTrR3yOVV72
# b53qBIuiKgkYMfb8Q/KuanfBrsAf9aw9GHU0bLPzMUoUuPLXYv3cYBFDSXFwKfUO
# O0MdF2IFSPceHjj9vXO0p5rTgW29Y38exisfTpfu6R983WHWBQ7/x33BngBHDCfb
# c1FRFaMnOEge6PVZxRDZuCPYMwz9THXRWEigPMOtupk89mYhQFCRqyjyotfBBPcr
# exhxS0prcjnKcVHovCPaEX8kRX32AmemcNURwe/E3yBQJQiedOGx4mGjaJ1jcJkt
# vDI3Z/C+5eJqURE15AeeWQ27LJP0p1T4MYM4Gdzr5D1VjCXjSjGTRHCqFYYxggHe
# MIIB2gIBATA9MCkxJzAlBgNVBAMMHk1hdHJpeCBIdWFuZyAtIENvZGUgU2lnbmlu
# ZyBDQQIQLyp1nLVk/oJLu4eggWVBxjAJBgUrDgMCGgUAoHgwGAYKKwYBBAGCNwIB
# DDEKMAigAoAAoQKAADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEE
# AYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQU5nUTMRZKgOET
# FBKSjSZg2U7YRxUwDQYJKoZIhvcNAQEBBQAEggEAdaZntECtBereT9l8Wz5010EJ
# M/1ojCVifVC9QqDjCViA/yPC22+4Q5s38rooC+QQtcaYWMIMT9ICUl1xn5KXC4Mu
# sfX9CYEpuqSH/OXknIuEvktf3uwe1ZIEpak+F7CElHi6F7hS/xJBjIQcWeQXF9k6
# h4IKAc4qorGA643HuZ6dxYssAwDTaIXq8CjFobbFJrvBfclegzjzrHDPE3gbK2Oi
# 9NB+wleiqGskp+6FmLbbilFmiwnspbrb8rMat0n6zuPq4RLATpXlVoyaiuCJLeMy
# uxmJM0OxwuFWHVXUJ0oixFMDMETUnMQ4mC9ABmSWSpZEYJH1pSg4CLEDAW55Lg==
# SIG # End signature block