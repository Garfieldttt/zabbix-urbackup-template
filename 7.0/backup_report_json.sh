#!/usr/bin/env bash
set -euo pipefail

DB="/var/urbackup/backup_server.db"
OUT="/var/log/urbackup-backups.json"

# Schreibprobe (legt Datei leer an / verifiziert Rechte)
: > "$OUT"

sqlite3 "$DB" > "$OUT" <<'SQL'
.mode json

-- Parametrisierbares Online-Fenster (Sekunden)
WITH params AS (
  SELECT 600 AS ONLINE_WINDOW
),
latest_backups AS (
  SELECT
    b.id,
    b.clientid,
    c.name AS BaseClient,
    b.backuptime,
    b.complete,
    b.done,
    ROUND(COALESCE(b.size_bytes,0) / 1024.0 / 1024.0, 1) AS File_Size_MB,
    COALESCE(l.errors, 0)   AS Errors,
    COALESCE(l.warnings, 0) AS Warnings,
    COALESCE(l.infos, 0)    AS Infos,
    CASE WHEN COALESCE(l.image, 0) > 0 THEN 1 ELSE 0 END AS is_image,
    c.lastseen,
    c.file_ok,
    c.image_ok,
    ROUND(COALESCE(c.bytes_used_files,0)  / 1024.0 / 1024.0, 1) AS Total_Used_Files_MB,
    ROUND(COALESCE(c.bytes_used_images,0) / 1024.0 / 1024.0, 1) AS Total_Used_Images_MB,
    ROUND((COALESCE(c.bytes_used_files,0) + COALESCE(c.bytes_used_images,0)) / 1024.0 / 1024.0, 1) AS Total_Used_MB,
    ROW_NUMBER() OVER (
      PARTITION BY b.clientid, CASE WHEN COALESCE(l.image, 0) > 0 THEN 1 ELSE 0 END
      ORDER BY
        CASE WHEN b.complete = 1 AND b.done = 1 THEN 0 ELSE 1 END,
        b.backuptime DESC
    ) AS rn_valid
  FROM backups b
  JOIN clients c ON c.id = b.clientid
  LEFT JOIN logs l ON l.id = b.id
)

-- 1) Beste (fertige) File- und Image-Backups pro Client/Typ
SELECT
  id AS Backup_ID,
  BaseClient || CASE is_image WHEN 1 THEN ' Image-Backup' ELSE ' File-Backup' END AS Client,
  CASE WHEN (strftime('%s','now') - COALESCE(lastseen,0)) < (SELECT ONLINE_WINDOW FROM params) THEN 'Yes' ELSE 'No' END AS Online,
  datetime(backuptime,'unixepoch') AS Backup_Time,
  CAST(backuptime AS TEXT) AS Backup_Timestamp,
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
        WHEN image_ok =  0 THEN 'no recent backup'
        WHEN image_ok <  0 THEN 'disabled'
        ELSE 'unknown'
      END
    ELSE 'unknown'
  END AS Status,
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

-- 2) Fehlende Image-Backups nur ergänzen, wenn kein valider Image-Eintrag existiert
SELECT
  0 AS Backup_ID,
  c.name || ' Image-Backup' AS Client,
  CASE WHEN (strftime('%s','now') - COALESCE(c.lastseen,0)) < (SELECT ONLINE_WINDOW FROM params) THEN 'Yes' ELSE 'No' END AS Online,
  'never' AS Backup_Time,
  '0'     AS Backup_Timestamp,
  CASE
    WHEN c.image_ok <  0 THEN 'disabled'
    WHEN c.image_ok =  0 THEN 'no recent backup'
    WHEN EXISTS (
      SELECT 1
      FROM backups b
      LEFT JOIN logs l ON l.id = b.id
      WHERE b.clientid = c.id
        AND COALESCE(l.image,0) > 0
        AND b.complete = 1 AND b.done = 1
        AND COALESCE(l.errors,0) <= 100
    ) THEN 'ok'
    WHEN EXISTS (
      SELECT 1
      FROM backups b
      LEFT JOIN logs l ON l.id = b.id
      WHERE b.clientid = c.id
        AND COALESCE(l.image,0) > 0
        AND b.complete = 1 AND b.done = 1
        AND COALESCE(l.errors,0) > 100
    ) THEN 'completed with issues'
    ELSE 'unknown'
  END AS Status,
  'image' AS Backup_Type,
  0 AS File_Size_MB,
  0 AS Errors,
  0 AS Warnings,
  0 AS Infos,
  ROUND(COALESCE(c.bytes_used_files,0)  / 1024.0 / 1024.0, 1) AS Total_Used_Files_MB,
  ROUND(COALESCE(c.bytes_used_images,0) / 1024.0 / 1024.0, 1) AS Total_Used_Images_MB,
  ROUND((COALESCE(c.bytes_used_files,0) + COALESCE(c.bytes_used_images,0)) / 1024.0 / 1024.0, 1) AS Total_Used_MB
FROM clients c
WHERE NOT EXISTS (
  SELECT 1 FROM latest_backups lb
  WHERE lb.clientid = c.id AND lb.is_image = 1 AND lb.rn_valid = 1
)

UNION ALL

-- 3) Fehlende File-Backups nur ergänzen, wenn kein valider File-Eintrag existiert
SELECT
  0 AS Backup_ID,
  c.name || ' File-Backup' AS Client,
  CASE WHEN (strftime('%s','now') - COALESCE(c.lastseen,0)) < (SELECT ONLINE_WINDOW FROM params) THEN 'Yes' ELSE 'No' END AS Online,
  'never' AS Backup_Time,
  '0'     AS Backup_Timestamp,
  'no recent backup' AS Status,
  'file' AS Backup_Type,
  0 AS File_Size_MB,
  0 AS Errors,
  0 AS Warnings,
  0 AS Infos,
  ROUND(COALESCE(c.bytes_used_files,0)  / 1024.0 / 1024.0, 1) AS Total_Used_Files_MB,
  ROUND(COALESCE(c.bytes_used_images,0) / 1024.0 / 1024.0, 1) AS Total_Used_Images_MB,
  ROUND((COALESCE(c.bytes_used_files,0) + COALESCE(c.bytes_used_images,0)) / 1024.0 / 1024.0, 1) AS Total_Used_MB
FROM clients c
WHERE c.file_ok = 0
  AND NOT EXISTS (
    SELECT 1 FROM latest_backups lb
    WHERE lb.clientid = c.id AND lb.is_image = 0 AND lb.rn_valid = 1
  )

ORDER BY Client, Backup_Type;
SQL
