@echo off
echo ========================================
echo   Augment Sheet Music Backend Setup
echo ========================================
echo.

python --version 2>nul
if %errorlevel% neq 0 (
    echo ERROR: Python is not installed or not in PATH
    echo Please install Python 3.11 or 3.12 from https://www.python.org/downloads/
    echo.
    echo NOTE: Python 3.13+ may have compatibility issues with music21
    pause
    exit /b 1
)

for /f "tokens=2 delims= " %%i in ('python --version 2^>^&1') do set PYVER=%%i
echo Detected Python version: %PYVER%
echo.

echo Checking Python version compatibility...
python -c "import sys; exit(0 if sys.version_info < (3, 13) else 1)" 2>nul
if %errorlevel% neq 0 (
    echo WARNING: Python 3.13+ detected. music21 may not work properly.
    echo Recommended: Install Python 3.11 or 3.12
    echo.
)

echo Installing dependencies...
pip install -r requirements.txt

echo.
echo ========================================
echo   Setup complete!
echo ========================================
echo.
echo To start the server:
echo   python app.py
echo.
pause
