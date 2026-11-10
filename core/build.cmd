@echo off
rem Builds FreeObdCore.exe with the C# compiler that ships with Windows (no SDK needed).
setlocal
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%~dp0bin" mkdir "%~dp0bin"
"%CSC%" /nologo /optimize+ /warn:4 /out:"%~dp0bin\FreeObdCore.exe" "%~dp0src\*.cs"
exit /b %ERRORLEVEL%
