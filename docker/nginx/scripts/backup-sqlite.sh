#!/bin/bash
# Writes a consistent snapshot of the SQLite database into the backup volume.
# Called by docker-volume-backup through the archive-pre label of the app
# container; a non-zero exit code makes the backup run fail and notify.
#
# The snapshot is created with VACUUM INTO (includes WAL content), checked
# with PRAGMA integrity_check and then atomically moved into place, so the
# backup volume never contains a partial file.
#
# SQLITE_BACKUP_SOURCE (required) is the path of the database, usually set
# with ENV in the project's Dockerfile. SQLITE_BACKUP_DIR defaults to the
# mount point of the backup volume.
set -euo pipefail

source_path=${SQLITE_BACKUP_SOURCE:-}
backup_dir=${SQLITE_BACKUP_DIR:-/var/www/backup}

if [ -z "$source_path" ]; then
    printf 'backup-sqlite: SQLITE_BACKUP_SOURCE is not set\n' >&2
    exit 1
fi

snapshot_path="$backup_dir/$(basename "$source_path")"
temporary_path="$backup_dir/.$(basename "$source_path").tmp.$$"

cleanup() {
    rm -f "$temporary_path"
}
trap cleanup EXIT

if [ ! -f "$source_path" ]; then
    printf 'backup-sqlite: source database not found: %s\n' "$source_path" >&2
    exit 1
fi

if [ ! -d "$backup_dir" ]; then
    printf 'backup-sqlite: backup directory not found: %s\n' "$backup_dir" >&2
    exit 1
fi

# shellcheck disable=SC2016 # PHP code, variables are expanded by PHP
php -r '
    [, $source, $target] = $argv;

    try {
        $database = new SQLite3($source, SQLITE3_OPEN_READONLY);
        $database->enableExceptions(true);
        $database->busyTimeout(5000);
        $statement = $database->prepare("VACUUM INTO :target");
        $statement->bindValue(":target", $target, SQLITE3_TEXT);
        $statement->execute();
        $database->close();

        $snapshot = new SQLite3($target, SQLITE3_OPEN_READONLY);
        $snapshot->enableExceptions(true);
        $result = $snapshot->querySingle("PRAGMA integrity_check");
        $snapshot->close();
    } catch (Throwable $exception) {
        fwrite(STDERR, "backup-sqlite: snapshot of {$source} failed: {$exception->getMessage()}\n");
        exit(1);
    }

    if ($result !== "ok") {
        fwrite(STDERR, "backup-sqlite: integrity check of snapshot failed: {$result}\n");
        exit(1);
    }
' -- "$source_path" "$temporary_path"

mv -f "$temporary_path" "$snapshot_path"
printf 'backup-sqlite: snapshot written: %s\n' "$snapshot_path"
