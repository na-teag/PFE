@echo off
setlocal EnableDelayedExpansion

REM ==================================================
REM Base plumbing (KEEP)
REM ==================================================

REM Fetch QEMU Guest Agent
msiexec /qb /i "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-qemu-ga/qemu-ga-x86_64.msi"

REM Install Chocolatey
powershell -NoProfile -InputFormat None -ExecutionPolicy Bypass -Command ^
 "Set-ExecutionPolicy Bypass -Scope Process -Force; ^
  [System.Net.ServicePointManager]::SecurityProtocol = ^
  [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; ^
  iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"

REM Install SPICE agent (optional but recommended)
choco install spice-agent -y

REM Create file indicating system is not yet sysprepped
copy C:\windows\system32\cmd.exe C:\not-yet-finished

REM ==================================================
REM Cuckoo analysis VM customization
REM ==================================================

REM Disable Windows Defender
powershell -Command "Set-MpPreference -DisableRealtimeMonitoring $true"
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" ^
 /v DisableAntiSpyware /t REG_DWORD /d 1 /f

REM Disable Windows Update
sc stop wuauserv || echo Windows Update already stopped
sc config wuauserv start= disabled

REM Disable UAC
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" ^
 /v EnableLUA /t REG_DWORD /d 0 /f

REM Install Python + Git
choco install python --version=3.11.6 git -y
call refreshenv

REM Install Cuckoo3 agent
if not exist C:\cuckoo3 (
  git clone https://github.com/cuckoosandbox/cuckoo3.git C:\cuckoo3
)

pushd C:\cuckoo3\agent
pip install --upgrade pip
pip install -r requirements.txt
popd

REM Configure agent
(
echo [agent]
echo host = 192.168.100.1
echo port = 8000
) > C:\cuckoo3\agent\agent.conf

REM Install agent as service
sc create cuckoo-agent ^
 binPath= "\"C:\Python311\python.exe\" \"C:\cuckoo3\agent\agent.py\"" ^
 start= auto

sc start cuckoo-agent

endlocal

