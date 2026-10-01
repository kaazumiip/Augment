@echo off
echo Starting Python backend for sheet music generation...
echo.
echo Make sure you have Python installed and dependencies:
echo   pip install -r requirements.txt
echo.
echo LilyPond is used for rendering sheet music images.
echo Install via: winget install LilyPond.LilyPond
echo.

cd /d "%~dp0"
set "PYTHON_EXE=%~dp0venv311\Scripts\python.exe"
if exist "%PYTHON_EXE%" (
    "%PYTHON_EXE%" app.py
) else (
    echo Project virtual environment not found. Falling back to Python 3.11.
    py -3.11 app.py
)
