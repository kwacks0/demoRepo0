@echo off
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "NvidiaGpuBenchmark_V1-3.ps1"
