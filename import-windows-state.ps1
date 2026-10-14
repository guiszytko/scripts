# import-windows-state.ps1
# Roda no Windows Server recem-instalado, DEPOIS de restaurar C:\BackupState
# a partir do backup do Bacula.
#
# Cada usuario recriado recebe uma senha ALEATORIA e UNICA (nao uma senha
# compartilhada) - a lista final fica salva em C:\BackupState\senhas-novas.csv
# Entregue a senha de cada um pra pessoa certa e apague o arquivo depois.

$In = "C:\BackupState"

if (-not (Test-Path $In)) {
    Write-Host "Pasta $In nao encontrada - restaure o backup primeiro."
    exit 1
}

function New-RandomPassword {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#$%'
    -join (1..14 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

$novasSenhas = @()

# Recriar usuarios, cada um com senha aleatoria propria
Import-Csv "$In\users.csv" | ForEach-Object {
    if (-not (Get-WmiObject Win32_UserAccount -Filter "Name='$($_.Name)'")) {
        $novaSenha = New-RandomPassword
        net user "$($_.Name)" "$novaSenha" /add
        $novasSenhas += [PSCustomObject]@{
            Usuario = $_.Name
            SenhaNova = $novaSenha
        }
        Write-Host "Usuario $($_.Name) criado com senha unica."
    }
}

# Exporta a lista de senhas novas (protege o arquivo so pro Administrador)
$senhasFile = "$In\senhas-novas.csv"
$novasSenhas | Export-Csv $senhasFile -NoTypeInformation -Encoding UTF8
icacls $senhasFile /inheritance:r /grant:r "Administradores:F" | Out-Null

# Recriar grupos locais (vazios)
Import-Csv "$In\groups.csv" | ForEach-Object {
    if (-not (Get-WmiObject Win32_Group -Filter "Name='$($_.Name)'")) {
        net localgroup "$($_.Name)" /add
    }
}

# Recriar compartilhamentos (pula os administrativos tipo C$, ADMIN$)
Import-Csv "$In\shares.csv" | ForEach-Object {
    if ($_.Name -notmatch '\$$' -and $_.Path) {
        net share "$($_.Name)"="$($_.Path)" /remark:"$($_.Description)"
    }
}

Write-Host ""
Write-Host "=========================================================="
Write-Host " Usuarios, grupos e shares recriados."
Write-Host ""
Write-Host " Senhas novas (unicas por usuario) salvas em:"
Write-Host "   $senhasFile"
Write-Host " Entregue cada senha pra pessoa certa e DEPOIS APAGUE esse"
Write-Host " arquivo (ele fica acessivel so pro Administrador, mas nao"
Write-Host " deve ficar armazenado indefinidamente)."
Write-Host ""
Write-Host " Passo manual restante:"
Write-Host "  1. Readicionar membros aos grupos usando $In\group_members.txt"
Write-Host ""
Write-Host " Restaurando permissoes NTFS por drive automaticamente..."
Get-ChildItem "$In\perms_drive_*.acl" -ErrorAction SilentlyContinue | ForEach-Object {
    $letter = ($_.BaseName -replace '^perms_drive_','')
    $drivePath = "$letter`:\"
    if (Test-Path $drivePath) {
        Write-Host "   Restaurando $drivePath (pode demorar em arvores grandes)..."
        icacls $drivePath /restore $_.FullName /c 2>$null
        Write-Host "   OK: $drivePath"
    } else {
        Write-Host "   AVISO: $drivePath nao existe neste servidor - pulei."
        Write-Host "   Restaure manualmente quando o drive existir: icacls $drivePath /restore `"$($_.FullName)`""
    }
}
Write-Host "=========================================================="
