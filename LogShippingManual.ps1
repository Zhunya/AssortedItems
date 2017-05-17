function Handle-Output($Object, $ForegroundColor="White", $NoNewLine=$false) {
        if ($host.Name -eq "ConsoleHost" -or $host.Name -eq "Windows PowerShell ISE Host") {
            if($NoNewLine){
                Write-Host -ForegroundColor $ForegroundColor -Object $Object -NoNewline
            } else {
                Write-Host -ForegroundColor $ForegroundColor -Object $Object
            }
        } else {
            Write-Output $Object
        }
}

function Handle-Progress($Activity, $Status, $PercentComplete, $Id) {
        if ($host.Name -eq "ConsoleHost" -or $host.Name -eq "Windows PowerShell ISE Host") {
            Write-Progress -Activity $Activity -Status $Status -Id $Id -
        }
}


function Get-LastRestoredLogTime($ServerInstance, $DatabaseName)
{
    $LastLogBackupQUERY = "
        SELECT TOP 1
	        b.backup_start_date
        FROM master.sys.databases d
        LEFT  OUTER JOIN msdb.dbo.[restorehistory] r ON r.[destination_database_name] = d.Name
        INNER JOIN msdb..backupset b ON b.backup_set_id = r.backup_set_id
            WHERE d.name = N'$DatabaseName'
        ORDER BY r.[restore_date] DESC
    "
    $LastLogBackupDate = Get-Date (Invoke-SqlCmd -ServerInstance $ServerInstance -Query $LastLogBackupQUERY).backup_start_date
    
    Return $LastLogBackupDate
}

function Invoke-LSRestore($ServerInstance, $DatabaseName,$BackupLocation,[switch]$Debug,[switch]$Standby,[switch]$NoRecovery)
{
    $FilesSkipped  = 0
    $FilesRestored = 0
 
    $now = Get-Date -Format U
    Handle-Output -Object "$now - Restore Started for $DatabaseName" -ForegroundColor "Green"
     
    $now = Get-Date -Format U
    Handle-Output -Object "$now - Settings:"    -ForegoundColor "Yellow"
    Handle-Output "`tServer:`t`t`t$ServerInstance"   -ForegoundColor "Yellow"
    Handle-Output "`tDatabase:`t`t$DatabaseName"   -ForegoundColor "Yellow"
    Handle-Output "`tBackup Source:`t$BackupLocation"    -ForegoundColor "Yellow"
 
    $FilesRestored = 0
 
    $LastLogBackupDate = Get-LastRestoredLogTime -ServerInstance $ServerInstance -DatabaseName $DatabaseName

    Handle-Output "`tLast restored backup file date and time:`t$LastLogBackupDate" -ForegoundColor "Yellow"

    if ($debug) {
        $now = Get-Date -Format U ; Handle-Output -Object "$now - Getting files in backup folder." -ForegoundColor "DarkCyan"
        $filesCount = (Get-ChildItem -path $BackupLocation\*.trn -File | Where-Object {$_.LastWriteTime -ge $LastLogBackupDate} ).Count
        Handle-Output "`tTotal files in directory: $filesCount" -ForegoundColor "Cyan"
    }
     
    get-childitem -path $BackupLocation\*.trn -File | Where-Object {$_.LastWriteTime -ge $LastLogBackupDate} | Sort-Object LastWriteTime | ForEach-Object {
        $trn_path = $_
        $trn_file = Split-Path -Leaf -Path $trn_path

        $sql = "
            declare @p3 bit
            set @p3=1
 
            exec master.sys.sp_can_tlog_be_applied 
                    @backup_file_name=N'$trn_path'
                ,@database_name=N'$DatabaseName'
                ,@result=@p3 output
 
            select @p3 [Result]"
             
        $ret = Invoke-SqlCmd -ServerInstance $ServerInstance -Query $sql | ForEach-Object {$_.Result}
         
        if ($ret)
        {
            $RestoreSQL = "
                RESTORE LOG [$DatabaseName] 
                FROM  DISK = N'$trn_path'
                WITH  NOUNLOAD,  STATS = 10"
                 
            if($Standby) {
                $RestoreSQL = $RestoreSQL + ", STANDBY =N'$DefaultBackupLocation\ROLLBACK_UNDO_$DatabaseName.TUF'";
            }
            if($NoRecovery) {
                $RestoreSQL = $RestoreSQL + ", NORECOVERY";
            }
             
#            if ($debug) {Handle-Output "Restore Script: $RestoreSQL" -ForeGroundColor "DarkCyan"}
             
            $now = Get-Date -Format u
#            Handle-Output -Object "$now - Attempting to restore: `'$trn_path`'" -ForeGroundColor "Yellow"
             
            $RestoreResult = Invoke-SqlCmd -ServerInstance $ServerInstance -Query $RestoreSQL -Database Master -ErrorAction Stop -QueryTimeout 600
             
#            if ($debug -eq $TRUE) {Handle-Output -Object $RestoreResult -ForegroundColor "DarkYellow"}
             
            $CheckRestoreSQL = "
                SELECT CAST(1 as bit) [IsRestored]
                FROM msdb.dbo.restorehistory h
                INNER JOIN msdb.dbo.backupset bs ON h.backup_set_id = bs.backup_set_id
                INNER JOIN msdb.dbo.backupmediafamily bmf ON bs.media_set_id = bmf.media_set_id
                WHERE
                    h.destination_database_name = '$DatabaseName'
                AND bmf.physical_device_name = '$trn_path'
                AND bs.[type]='L'
            "
             
#            if ($debug) {Handle-Output "Check Restore Script: $checkRestoreSQL" -ForegroundColor "DarkCyan"}
             
            $RestoreResult = $FALSE
            $RestoreResult = Invoke-SqlCmd -ServerInstance $ServerInstance -Query $CheckRestoreSQL | ForEach-Object {$_.IsRestored}

            if ($RestoreResult)
                {
                 #Handle-Output -Object "Restored Successfully ($trn_file)`n" -ForegroundColor "Green"
                }
            else
                {
                Throw "Restore Failed! [$trn_file]"
                }

            $FilesRestored ++;
            Handle-Output -Object "+" -ForegroundColor "Yellow" -NoNewLine $true
        } else {
            $FilesSkipped ++
            Handle-Output -Object "-" -ForegroundColor "DarkCyan" -NoNewLine $true
#            if ($debug) { Handle-Output -Object "Skipping file ($trn_file)`n" -ForegroundColor "DarkCyan"}
        }
    }     
    Handle-Output -Object " "
    Handle-Output -Object "Number of files restored $FilesRestored." -ForegroundColor "Green"
    Handle-Output -Object "Number of files skipped  $FilesSkipped." -ForegroundColor "Cyan"
}

$dbList = ('database_to_restore_log') 
$ServerInstance = 'yourSQLServerInstanceName'

ForEach($dbName in $dbList)
{
 $sourcePath = '\\srv-backup\SQLBackup\'
 
 $sourcePath += $dbName + '\LOG\'
 $dbName += ''
 Invoke-LSRestore -debug -ServerInstance $ServerInstance -DatabaseName $dbName -BackupLocation $sourcePath -NoRecovery
}
