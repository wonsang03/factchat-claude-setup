@echo off

rem ------------------------------------------------------------------
rem  PATH 가 망가진 PC 에서도 동작하도록 윈도우 기본 경로를 앞에 붙임
rem  (이게 빠져 있으면 chcp, powershell 이 "내부 또는 외부 명령" 오류를 냄)
rem  chcp 보다 먼저 와야 함
rem ------------------------------------------------------------------
set "PATH=%SystemRoot%\System32;%SystemRoot%;%SystemRoot%\System32\Wbem;%SystemRoot%\System32\WindowsPowerShell\v1.0;%PATH%"

chcp 65001 >nul
title Claude Code Setup

rem ------------------------------------------------------------------
rem  이 bat 파일이 있는 폴더를 작업 폴더로 삼음
rem  (네트워크 폴더에서도 되도록 pushd 를 먼저 시도)
rem ------------------------------------------------------------------
pushd "%~dp0"
if errorlevel 1 cd /d "%~dp0"

set "SETUP=%~dp0setup-claude.ps1"
if not exist "%SETUP%" goto NOSETUP

rem ------------------------------------------------------------------
rem  PowerShell 을 PATH 에 기대지 않고 절대 경로로 찾음
rem ------------------------------------------------------------------
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%PS%" goto RUN
set "PS=%SystemRoot%\SysNative\WindowsPowerShell\v1.0\powershell.exe"
if exist "%PS%" goto RUN
set "PS=%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
if exist "%PS%" goto RUN
set "PS=powershell.exe"
where powershell.exe >nul 2>nul
if errorlevel 1 goto NOPOWERSHELL

:RUN
echo.
echo  실행 위치 : %CD%
echo  설정 파일 : %SETUP%
echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SETUP%"
set "RC=%ERRORLEVEL%"
popd
echo.
if not "%RC%"=="0" echo  [알림] 설정이 끝까지 진행되지 않았습니다. 위 메시지를 확인하세요.
pause
exit /b %RC%

:NOSETUP
echo.
echo  [오류] setup-claude.ps1 파일을 찾을 수 없습니다.
echo         찾은 위치: %SETUP%
echo.
echo  이 bat 파일과 setup-claude.ps1, .env 를 같은 폴더에 두세요.
echo  압축 파일을 풀지 않고 안에서 바로 실행하면 이 오류가 납니다.
echo  압축을 푼 뒤 그 폴더에서 다시 실행하세요.
echo.
pause
exit /b 1

:NOPOWERSHELL
echo.
echo  [오류] 이 컴퓨터에서 PowerShell 을 찾지 못했습니다.
echo.
echo  확인할 것
echo    1) 아래 폴더에 powershell.exe 가 있는지 확인
echo       %SystemRoot%\System32\WindowsPowerShell\v1.0
echo    2) 있으면 PATH 환경변수가 망가진 것이니 담당 교수에게 문의
echo    3) 없으면 Windows 업데이트 후 다시 시도
echo.
pause
exit /b 1
