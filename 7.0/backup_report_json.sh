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
    COALESCE(l.errors, 0)   AS Errors,
    COALESCE(l.warnings, 0) AS Warnings,
    COALESCE(l.infos, 0)    AS Infos,
    -- Neues Flag für Image-Backup: 1 wenn >0, sonst 0
    CASE WHEN COALESCE(l.image, 0) > 0 THEN 1 ELSE 0 END AS is_image,
    c.lastseen,
    c.file_ok,
    c.image_ok,
    ROUND(c.bytes_used_files   / 1024.0 / 1024.0, 1) AS Total_Used_Files_MB,
    ROUND(c.bytes_used_images  / 1024.0 / 1024.0, 1) AS Total_Used_Images_MB,
    ROUND((c.bytes_used_files + c.bytes_used_images) / 1024.0 / 1024.0, 1) AS Total_Used_MB,
    ROW_NUMBER() OVER (
      PARTITION BY b.clientid, CASE WHEN COALESCE(l.image, 0) > 0 THEN 1 ELSE 0 END
      ORDER BY
        CASE WHEN complete = 1 AND done = 1 THEN 0 ELSE 1 END,
        b.backuptime DESC
    ) AS rn_valid
  FROM backups b
  JOIN clients c ON c.id = b.clientid
  LEFT JOIN logs l   ON l.id = b.id
)

-- 1) Alle neuesten Backups (File + Image) mit Status aus clients.file_ok / image_ok
SELECT
  id                                            AS Backup_ID,
  BaseClient
    || CASE is_image WHEN 1 THEN ' Image-Backup' ELSE ' File-Backup' END
                                                  AS Client,
  CASE
    WHEN strftime('%s','now') - strftime('%s', lastseen) < 600 THEN 'Yes'
    ELSE 'No'
  END                                           AS Online,
  strftime('%Y-%m-%d %H:%M:%S', backuptime)     AS Backup_Time,
  strftime('%s', backuptime)                   AS Backup_Timestamp,
  CASE
    WHEN is_image = 0 THEN
      CASE
        WHEN file_ok  >  0 THEN 'ok'
        WHEN file_ok  =  0 THEN 'no recent backup'
        WHEN file_ok  <  0 THEN 'completed with issues'
        ELSE 'unknown'
      END
    WHEN is_image = 1 THEN
      CASE
        WHEN image_ok >  0 THEN 'ok'
        WHEN image_ok =  0 THEN 'disabled'
        WHEN image_ok <  0 THEN 'not supported'
        ELSE 'unknown'
      END
    ELSE 'unknown'
  END                                           AS Status,
  CASE is_image WHEN 1 THEN 'image' ELSE 'file' END AS Backup_Type,
  File_Size_MB,
  Errors,
  Warnings,
  Infos,
  Total_Used_Files_MB,
  Total_Used_Images_MB,
  Total_Used_MB
FROM latest_backups
WHERE rn_valid = 1

UNION ALL

-- 2) Fehlende Image-Backups ergänzen, Status aus clients.image_ok
SELECT
  0                                             AS Backup_ID,
  c.name || ' Image-Backup'                     AS Client,
  CASE
    WHEN strftime('%s','now') - strftime('%s', c.lastseen) < 600 THEN 'Yes'
    ELSE 'No'
  END                                           AS Online,
  'never'                                       AS Backup_Time,
  '0'                                           AS Backup_Timestamp,
  CASE
    WHEN EXISTS (
      SELECT 1
      FROM backups b
      JOIN logs l ON l.id = b.id
      WHERE b.clientid = c.id
        AND COALESCE(l.image,0) > 0
        AND b.complete = 1
        AND b.done = 1
        AND l.errors <= 100
    ) THEN 'ok'
    WHEN EXISTS (
      SELECT 1
      FROM backups b
      JOIN logs l ON l.id = b.id
      WHERE b.clientid = c.id
        AND COALESCE(l.image,0) > 0
        AND b.complete = 1
        AND b.done = 1
        AND l.errors > 100
    ) THEN 'completed with issues'
    WHEN c.image_ok =  0 THEN 'disabled'
    WHEN c.image_ok <  0 THEN 'not supported'
    ELSE 'no recent backup'
  END                                           AS Status,
  'image'                                       AS Backup_Type,
  0                                             AS File_Size_MB,
  0                                             AS Errors,
  0                                             AS Warnings,
  0                                             AS Infos,
  ROUND(c.bytes_used_files   / 1024.0 / 1024.0, 1) AS Total_Used_Files_MB,
  ROUND(c.bytes_used_images  / 1024.0 / 1024.0, 1) AS Total_Used_Images_MB,
  ROUND((c.bytes_used_files + c.bytes_used_images) / 1024.0 / 1024.0, 1)
                                                  AS Total_Used_MB
FROM clients c

ORDER BY Client, Backup_Type;
EOF
