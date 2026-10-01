@echo off
echo Starting Node.js backend server...
echo.
echo Make sure you have installed dependencies:
echo   npm install
echo.
echo The Python backend should be running on port 5000
echo Start it separately with: python\start.bat
echo.

cd /d "%~dp0"
npm run dev
