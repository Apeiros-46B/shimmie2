<?php

declare(strict_types=1);

/**
 * Run the shimmie2 database upgrade for extensions.
 *
 * Fires DatabaseUpgradeEvent, which causes every installed extension to check whether
 * its database tables exist and create them if not. This runs on every boot so that
 * newly-enabled extensions get their tables before apply_seeds runs.
 *
 * This should be idempotent since extensions' upgrade handlers are idempotent.
 */

namespace Shimmie2;

require_once "vendor/autoload.php";

_set_up_shimmie_environment();
Ctx::$tracer = new \MicroOTLP\Client();
Ctx::$root_span = Ctx::$tracer->startSpan("Upgrade");

require_once "core/Util/util.php";

// provides DATABASE_DSN
require_once "data/config/shimmie.conf.php";

// provides EXTRA_EXTS. without it, non-core extensions are accidentally skipped
require_once "data/config/extensions.conf.php";

_load_ext_files();

$dsn = defined("DATABASE_DSN") ? constant("DATABASE_DSN") : null;
if (!$dsn) {
    fwrite(STDERR, "upgrade_db: DATABASE_DSN is not defined\n");
    exit(1);
}

try {
    $db = new Database($dsn);

    echo "upgrade_db: running database upgrade for extensions...\n";
    Ctx::$cache = load_cache(SysConfig::getCacheDsn());
    Ctx::$database = $db;
    Ctx::$config = new DatabaseConfig(Ctx::$database);
    Ctx::$event_bus = new EventBus();
    send_event(new DatabaseUpgradeEvent());

    $db->commit();

    echo "upgrade_db: done\n";
} catch (\Throwable $e) {
    fwrite(STDERR, "upgrade_db: " . $e->getMessage() . "\n");
    exit(1);
}
