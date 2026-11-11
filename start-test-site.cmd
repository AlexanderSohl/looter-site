@echo off
rem Starts the local test website (game + accounts + leaderboard) on http://localhost:8080.
rem Build the game first in Unity: Looter -> Build WebGL Test.
rem Optional: set GOOGLE_CLIENT_ID=<your web client id> before running to enable Google sign-in.
cd /d "%~dp0"

if not exist "public\play\index.html" (
  echo No game build found in public\play. In Unity run: Looter -^> Build WebGL Test
  echo The website will still start, but the game frame will be empty.
  echo.
)

if not exist "node_modules" (
  echo First run: installing server packages...
  call npm install --no-audit --no-fund || goto :failed
  call npm install-scripts approve better-sqlite3 >nul 2>&1
  call npm rebuild better-sqlite3 || goto :failed
)

rem Open the browser after a short delay so the server is already listening.
start "" /b cmd /c "timeout /t 2 /nobreak >nul & start http://localhost:8080"
call npm start
goto :eof

:failed
echo.
echo npm install failed. Check that Node.js 20+ is installed (node --version).
pause
