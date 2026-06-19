<?php

declare(strict_types=1);

/**
 * Bootstrap the shimmie2 core database tables.
 *
 * The NixOS module pre-creates data/config/shimmie.conf.php, which causes the normal
 * installer (Installer::install()) to be skipped entirely, but
 * Installer::create_tables() is the only code path that creates the essential tables
 * (config, users, images, tags, image_tags).
 *
 * This script loads just enough of shimmie to connect to the database and run
 * create_tables() if needed. Idempotent; if the config table exists it does nothing.
 *
 * Database upgrades for extensions are handled separately by upgrade_db.php.
 */

namespace Shimmie2;

require_once "vendor/autoload.php";

// minimal env so _load_ext_files() doesn't crash on Ctx::$tracer
_set_up_shimmie_environment();
Ctx::$tracer = new \MicroOTLP\Client();
Ctx::$root_span = Ctx::$tracer->startSpan("Bootstrap");

require_once "core/Util/util.php";

// Load the nix-managed config to get DATABASE_DSN.
require_once "data/config/shimmie.conf.php";

_load_ext_files();

$dsn = defined("DATABASE_DSN") ? constant("DATABASE_DSN") : null;
if (!$dsn) {
    fwrite(STDERR, "install_db: DATABASE_DSN is not defined\n");
    exit(1);
}

try {
    $db = new Database($dsn);

    try {
        $db->execute("SELECT 1 FROM config LIMIT 1");
        echo "install_db: tables already exist\n";
        exit(0);
    } catch (DatabaseException) {
        // config table missing
    }

    echo "install_db: creating core tables...\n";
    Installer::create_tables($db);

    echo "install_db: done\n";
} catch (\Throwable $e) {
    fwrite(STDERR, "install_db: " . $e->getMessage() . "\n");
    exit(1);
}
