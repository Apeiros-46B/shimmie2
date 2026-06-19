<?php

declare(strict_types=1);

/**
 * Apply declarative SQL initialization to the shimmie2 database.
 *
 * Reads a JSON spec written by the NixOS module with this shape:
 *
 *   {
 *     "dataDir": "/srv/shimmie-test",
 *     "entries": [
 *       {
 *         "requires": ["image_tag_categories"],
 *         "sql": "INSERT INTO image_tag_categories VALUES ('test', ...);",
 *         "oneshot": true
 *       }
 *     ]
 *   }
 *
 * For each entry the script:
 *  - Skips if any required table is missing (with a warning).
 *  - For oneshot=true: checks a marker file in dataDir. Named entries use a stable
 *    marker that persists across SQL changes. Unnamed entries use a key based on
 *    content hash, so changing any field creates a new marker and reruns the entry.
 *  - For oneshot=false: executes unconditionally on every startup.
 *
 * This runs on every startup (after the init stamp guard) so that changes to
 * seedSql in the Nix configuration are applied without a full redeploy.
 */

namespace Shimmie2;

require_once "vendor/autoload.php";

// Minimal Ctx setup so Database works.
_set_up_shimmie_environment();
Ctx::$tracer = new \MicroOTLP\Client();
Ctx::$root_span = Ctx::$tracer->startSpan("Seed");

require_once "core/Util/util.php";

// Load the nix-managed config to get DATABASE_DSN.
require_once "data/config/shimmie.conf.php";

_load_ext_files();

$dsn = defined("DATABASE_DSN") ? constant("DATABASE_DSN") : null;
if (!$dsn) {
    fwrite(STDERR, "apply_seeds: DATABASE_DSN is not defined\n");
    exit(1);
}

$specPath = $argv[1] ?? null;
if (!$specPath) {
    fwrite(STDERR, "usage: apply_seeds.php <spec.json>\n");
    exit(1);
}

try {
    $spec = \Safe\json_decode(\Safe\file_get_contents($specPath), true);
    if (!is_array($spec)) {
        throw new \Exception("seed spec is not a valid JSON object");
    }

    $dataDir = $spec["dataDir"] ?? "";
    if (!is_dir($dataDir)) {
        throw new \Exception("dataDir does not exist: $dataDir");
    }
    $entries = $spec["entries"] ?? [];
    if (!is_array($entries)) {
        throw new \Exception("entries is not an array");
    }

    // Stamp guard in init service already ensures DB + tables exist.
    $db = new Database($dsn);

    foreach ($entries as $idx => $entry) {
        $name = $entry["name"] ?? null;
        printf("apply_seeds: entry %d (%s)... ", $idx, $name ?? "unnamed");

        $requires = $entry["requires"] ?? [];
        if (!is_array($requires)) {
            $requires = [];
        }
        $sql = $entry["sql"] ?? "";
        if (!is_string($sql) || trim($sql) === "") {
            echo "skipped (empty sql)\n";
            continue;
        }
        $oneshot = (bool)($entry["oneshot"] ?? false);

        // check for required tables
        $missing = [];
        foreach ($requires as $table) {
            try {
                $db->execute("SELECT 1 FROM \"$table\" LIMIT 1");
            } catch (DatabaseException) {
                $missing[] = $table;
            }
        }
        if ($missing) {
            printf("skipped (missing tables: %s)\n", implode(", ", $missing));
            continue;
        }

        // skip oneshots if already executed
        if ($oneshot) {
            if (is_string($name) && $name !== "") {
                $marker = "$dataDir/.seed-$name";
                if (file_exists($marker)) {
                    // named entries skipped even if sql differs
                    echo "skipped (marker exists)\n";
                    continue;
                }
            } else {
                // derive content address
                $key = hash("sha256", \Safe\json_encode($entry));
                $marker = "$dataDir/.seed-$key";
                if (file_exists($marker)) {
                    echo "skipped (hash unchanged)\n";
                    continue;
                }
            }
        }

        // Execute.
        $db->execute($sql);
        echo "done\n";

        if ($oneshot) {
            \Safe\file_put_contents($marker, is_string($name) && $name !== "" ? $name : ($key ?? ""));
        }
    }

    $db->commit();

    echo "apply_seeds: done\n";
} catch (\Throwable $e) {
    fwrite(STDERR, "apply_seeds: " . $e->getMessage() . "\n");
    exit(1);
}
