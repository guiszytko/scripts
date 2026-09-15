@echo off
setlocal enabledelayedexpansion
title Gerador de config do Bacula File Daemon

echo ============================================================
echo  Gerador de bacula-fd.conf (nao depende de download)
echo ============================================================
echo.

set /p DIRETORADDR="IP do servidor Bacula: "
set /p DIRNAME="Nome do Director (ex: poquema-dir): "
set /p CLIENTNAME="Nome deste client (ex: pqsrv01): "
set /p CLIENTPASS="Senha do client (a mesma cadastrada no servidor): "

for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /c:"IPv4"') do set MYIP=%%a
set MYIP=%MYIP: =%
set /p CLIENTADDR="IP deste servidor Windows [%MYIP%]: "
if "%CLIENTADDR%"=="" set CLIENTADDR=%MYIP%

set MONPASS=%RANDOM%%RANDOM%%RANDOM%

set BACULA_DIR=C:\Program Files\Bacula
set CONF_FILE=%BACULA_DIR%\bacula-fd.conf
set OUT_FILE=bacula-fd.conf

if exist "%BACULA_DIR%" (
    set OUT_FILE=%CONF_FILE%
    echo Pasta do Bacula encontrada, vou escrever direto em:
    echo   %CONF_FILE%
) else (
    echo Pasta do Bacula NAO encontrada em "%BACULA_DIR%".
    echo Vou gerar o arquivo aqui mesmo, nesta pasta, com o nome bacula-fd.conf.
    echo Depois de instalar o Bacula, copie esse arquivo para dentro da pasta
    echo de instalacao dele, substituindo o bacula-fd.conf que ja existir.
)

if exist "%CONF_FILE%" (
    copy "%CONF_FILE%" "%CONF_FILE%.bak" >nul
    echo Backup do arquivo antigo salvo como bacula-fd.conf.bak
)

(
echo #
echo # bacula-fd.conf gerado automaticamente
echo #
echo FileDaemon {
echo   Name = %CLIENTNAME%-fd
echo   FDport = 9102
echo   WorkingDirectory = "C:\\Program Files\\Bacula\\working"
echo   Pid Directory = "C:\\Program Files\\Bacula\\working"
echo   Plugin Directory = "C:\\Program Files\\Bacula\\plugins"
echo   Maximum Concurrent Jobs = 5
echo   TLS Enable = no
echo   TLS PSK Enable = no
echo }
echo.
echo Director {
echo   Name = %DIRNAME%
echo   Password = "%CLIENTPASS%"
echo   TLS Enable = no
echo   TLS PSK Enable = no
echo }
echo.
echo Director {
echo   Name = %CLIENTNAME%-mon
echo   Password = "%MONPASS%"
echo   Monitor = yes
echo   TLS Enable = no
echo   TLS PSK Enable = no
echo }
echo.
echo Messages {
echo   Name = Standard
echo   director = %DIRNAME% = all, !skipped, !restored, !verified
echo }
) > "%OUT_FILE%"

echo.
echo Arquivo gerado: %OUT_FILE%
echo.

if "%OUT_FILE%"=="%CONF_FILE%" (
    echo Reiniciando o servico...
    net stop "Bacula File Backup Service" >nul 2>&1
    net start "Bacula File Backup Service" >nul 2>&1

    echo Liberando a porta 9102 no firewall...
    netsh advfirewall firewall add rule name="Bacula FD" dir=in action=allow protocol=TCP localport=9102 remoteip=%DIRETORADDR% >nul 2>&1

    echo.
    echo ============================================================
    echo  Concluido! Confira o servico em services.msc
    echo ============================================================
) else (
    echo Copie o arquivo "%OUT_FILE%" para dentro de "%BACULA_DIR%\bacula-fd.conf"
    echo depois de instalar o Bacula File Daemon, e reinicie o servico manualmente.
)

pause
