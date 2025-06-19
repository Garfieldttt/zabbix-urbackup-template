#!/bin/bash

DB="/var/urbackup/backup_server.db"
OUT="/var/log/urbackup-backups.json"

sqlite3 "$DB" <<EOF > "$OUT"
.headers on
.mode json

WITH latest_backups AS (
  SELECT
    b.id,
    b.clientid,
    c.name AS BaseClient,
    b.backuptime,
    b.complete,
    b.done,
    ROUND(b.size_bytes / 1024.0 / 1024.0, 1) AS File_Size_MB,
    COALESCE(l.errors, 0) AS errors,
    COALESCE(l.warnings, 0) AS warnings,
    COALESCE(l.infos, 0) AS infos,
    COALESCE(l.image, 0) AS image,
    c.lastseen,
    ROUND(c.bytes_used_files / 1024.0 / 1024.0, 1) AS Total_Used_Files_MB,
    ROUND(c.bytes_used_images / 1024.0 / 1024.0, 1) AS Total_Used_Images_MB,
    ROUND((c.bytes_used_files + c.bytes_used_images) / 1024.0 / 1024.0, 1) AS Total_Used_MB,
    ROW_NUMBER() OVER (
      PARTITION BY b.clientid, COALESCE(l.image, 0)
      ORDER BY CASE WHEN complete = 1 AND done = 1 THEN 0 ELSE 1 END, b.backuptime DESC
    ) AS rn_valid
  FROM backups b
  JOIN clients c ON c.id = b.clientid
  LEFT JOIN logs l ON l.id = b.id
)

SELECT
  id AS Backup_ID,
  BaseClient || CASE image WHEN 1 THEN ' Image-Backup' ELSE ' File-Backup' END AS Client,
  CASE
    WHEN strftime('%s','now') - strftime('%s', lastseen) < 600 THEN 'Yes'
    ELSE 'No'
  END AS Online,
  strftime('%Y-%m-%d %H:%M:%S', backuptime) AS Backup_Time,
  strftime('%s', backuptime) AS Backup_Timestamp,
  CASE
    WHEN complete = 0 THEN 'no recent backup'
    WHEN done = 0 THEN 'failed'
    WHEN complete = 1 AND errors > 100 THEN 'completed with issues'
    WHEN complete = 1 AND errors <= 100 THEN 'ok'
    ELSE 'unknown'
  END AS Status,
  CASE image WHEN 1 THEN 'image' ELSE 'file' END AS Backup_Type,
  File_Size_MB,
  errors AS Errors,
  warnings AS Warnings,
  infos AS Infos,
  Total_Used_Files_MB,
  Total_Used_Images_MB,
  Total_Used_MB
FROM latest_backups
WHERE rn_valid = 1

UNION ALL

-- Clients with enabled image backups but no successful image backup yet
SELECT
  0 AS Backup_ID,
  c.name || ' Image-Backup' AS Client,
  CASE
    WHEN strftime('%s','now') - strftime('%s', c.lastseen) < 600 THEN 'Yes'
    ELSE 'No'
  END AS Online,
  'never' AS Backup_Time,
  '0' AS Backup_Timestamp,
  'no recent backup' AS Status,
  'image' AS Backup_Type,
  0 AS File_Size_MB,
  0 AS Errors,
  0 AS Warnings,
  0 AS Infos,
  ROUND(c.bytes_used_files / 1024.0 / 1024.0, 1) AS Total_Used_Files_MB,
  ROUND(c.bytes_used_images / 1024.0 / 1024.0, 1) AS Total_Used_Images_MB,
  ROUND((c.bytes_used_files + c.bytes_used_images) / 1024.0 / 1024.0, 1) AS Total_Used_MB
FROM clients c
WHERE c.image_ok = 1
  AND NOT EXISTS (
    SELECT 1
    FROM backups b
    JOIN logs l ON l.id = b.id
    WHERE b.clientid = c.id AND l.image = 1 AND b.complete = 1 AND b.done = 1
  )

ORDER BY Client, Backup_Type;

EOF

