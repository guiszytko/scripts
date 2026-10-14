# export-windows-state.ps1
# Roda no Windows Server ANTES de cada backup do Bacula (via Client Run Before Job).
# Usa WMI/net em vez de Get-LocalUser/Get-SmbShare pra funcionar mesmo sem WMF 5.1.
# Salva tudo em C:\BackupState, que entra no FileSet do Bacula.
#
# IMPORTANTE: captura permissoes NTFS de TODOS os drives locais fixos
# (nao so os que estao compartilhados via SMB) - cobre o caso de pastas
# com permissao por usuario mesmo sem share formal (ex: L:\Pasta-do-Joao).

$Out = "C:\BackupState"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
Remove-Item "$Out\*" -Force -ErrorAction SilentlyContinue

# Usuarios locais
Get-WmiObject Win32_UserAccount -Filter "LocalAccount=True" |
    Select-Object Name, SID, Disabled, Lockout, PasswordRequired |
    Export-Csv "$Out\users.csv" -NoTypeInformation -Encoding UTF8

# Grupos locais
Get-WmiObject Win32_Group -Filter "LocalAccount=True" |
    Select-Object Name, SID |
    Export-Csv "$Out\groups.csv" -NoTypeInformation -Encoding UTF8

# Membros de cada grupo (formato texto, restauracao e manual)
Remove-Item "$Out\group_members.txt" -Force -ErrorAction SilentlyContinue
foreach ($g in (Get-WmiObject Win32_Group -Filter "LocalAccount=True")) {
    "=== $($g.Name) ===" | Out-File -Append "$Out\group_members.txt" -Encoding UTF8
    net localgroup "$($g.Name)" | Out-File -Append "$Out\group_members.txt" -Encoding UTF8
}

# Compartilhamentos SMB (nome, caminho, descricao) - so pra referencia de nomes
Get-WmiObject Win32_Share |
    Select-Object Name, Path, Description |
    Export-Csv "$Out\shares.csv" -NoTypeInformation -Encoding UTF8

# Permissoes NTFS de CADA DRIVE LOCAL FIXO (recursivo, pasta por pasta),
# independente de ser compartilhado via SMB ou nao. Isso cobre o caso de
# pastas com permissao restrita por usuario (ex: L:\Financeiro so financeiro,
# L:\RH so RH) mesmo que a pasta nao seja um share formal.
$drives = Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" |
    Where-Object { $_.DeviceID -ne "C:" }

Remove-Item "$Out\drives_backed_up.txt" -Force -ErrorAction SilentlyContinue
foreach ($d in $drives) {
    $letter = $d.DeviceID -replace ':',''
    Write-Host "Salvando permissoes NTFS de $($d.DeviceID)\ (pode demorar em arvores grandes)..."
    icacls "$($d.DeviceID)\" /save "$Out\perms_drive_$letter.acl" /t /c 2>$null
    "$($d.DeviceID)\" | Out-File -Append "$Out\drives_backed_up.txt" -Encoding UTF8
}

Write-Host "Export concluido em $Out"
Write-Host "Drives com permissao NTFS salva: $($drives.DeviceID -join ', ')"
