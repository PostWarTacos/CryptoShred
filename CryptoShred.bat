REM filepath: c:\Users\wurtzmt\Documents\Coding\CryptoShred\CryptoShred.bat
@echo off
setlocal ENABLEDELAYEDEXPANSION

REM === CONFIGURATION ===
set VERACRYPT_PATH=%~dp0VeraCrypt.exe

REM === LIST PHYSICAL DRIVES ===
echo Listing physical drives:
echo list disk > %~dp0listdisk.txt
diskpart /s %~dp0listdisk.txt
del %~dp0listdisk.txt

echo.
set /p DISKNUM="Enter the disk number to crypto-shred (e.g., 1): "
set TARGET=\\.\PhysicalDrive%DISKNUM%

REM === CONFIRMATION ===
echo WARNING: This will DESTROY ALL DATA on %TARGET%!
set /p CONFIRM="Type YES to continue: "
if /I not "%CONFIRM%"=="YES" goto :EOF

REM === GENERATE RANDOM PASSWORD ===
set KEYFILE=%~dp0vc_keyfile.bin
set PASSWORD_FILE=%~dp0vc_password.txt
setlocal
set "RANDOM_PASS="
for /L %%A in (1,1,32) do set /a "R=!random! %% 62" & call set "RANDOM_PASS=!RANDOM_PASS!!R!"
echo !RANDOM_PASS! > "%PASSWORD_FILE%"
endlocal & set /p VC_PASSWORD=<"%PASSWORD_FILE%"

REM === CREATE RANDOM KEYFILE ===
%VERACRYPT_PATH% /CreateKeyfile "%KEYFILE%" /RandomSource Random

REM === ENCRYPT ENTIRE PHYSICAL DRIVE ===
echo Encrypting entire physical drive %TARGET% ...
%VERACRYPT_PATH% /volume %TARGET% /format /password "%VC_PASSWORD%" /keyfiles "%KEYFILE%" /encryption AES /hash SHA-512 /filesystem NTFS /silent
if errorlevel 1 (
    echo VeraCrypt failed to encrypt the drive. Aborting.
    goto :CLEANUP
)

REM === DELETE KEYFILE AND PASSWORD ===
del /f /q "%KEYFILE%"
del /f /q "%PASSWORD_FILE%"

REM === SHRED COMPLETE ===
echo Crypto-shredding complete. Data is now unrecoverable.
pause

:CLEANUP
endlocal