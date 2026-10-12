@echo off
rem ==========================================================================
rem AI Job Hunter - credential injector (Windows launcher)
rem
rem CMD on this machine resolves `bash` to a broken WSL install, so this
rem calls Git Bash explicitly and runs set-credentials.sh from the project
rem root. Usage (from anywhere):
rem
rem   scripts\set-credentials.bat
rem   scripts\set-credentials.bat --show
rem   scripts\set-credentials.bat --generate
rem ==========================================================================
setlocal
set "BASH=C:\Program Files\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=C:\Program Files\Git\usr\bin\bash.exe"
if not exist "%BASH%" (
  echo FAIL  Git Bash not found. Install Git for Windows, or run from a Git Bash terminal:
  echo       bash scripts/set-credentials.sh
  exit /b 1
)

set "ROOT=%~dp0.."
pushd "%ROOT%" || exit /b 1
"%BASH%" scripts/set-credentials.sh %*
set "RC=%ERRORLEVEL%"
popd
exit /b %RC%
