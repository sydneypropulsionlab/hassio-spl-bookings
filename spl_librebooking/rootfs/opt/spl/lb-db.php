<?php
/**
 * Database helper for the SPL Equipment Booking add-on.
 *
 * Runs LibreBooking's own Installer class from the command line, so a first start
 * installs the schema and later starts apply LibreBooking's database upgrades, the
 * same way the web installer (/Web/install) does.
 *
 * Usage: php lb-db.php <status|install|upgrade> [app-root]
 *   status   prints "empty", "installed <version>" or "foreign <n tables>"
 *   install  installs the schema and initial data into an EMPTY database only
 *   upgrade  applies upgrade scripts newer than the installed version
 *
 * Connection details come from LibreBooking's normal settings (LB_DATABASE_* environment
 * variables). Unlike the web installer this never drops or creates the database or user:
 * the add-on creates those itself with IF NOT EXISTS before calling this script.
 */

$command = $argv[1] ?? '';
$root = rtrim($argv[2] ?? '/var/www/html', '/') . '/';

define('ROOT_DIR', $root);
chdir(ROOT_DIR);

// Same bootstrap order as Pages/Page.php, which the web installer loads.
require_once(ROOT_DIR . 'vendor/autoload.php');
require_once(ROOT_DIR . 'lib/Common/namespace.php');
require_once(ROOT_DIR . 'lib/Server/namespace.php');
require_once(ROOT_DIR . 'lib/Config/namespace.php');
require_once(ROOT_DIR . 'Presenters/Install/Installer.php');
require_once(ROOT_DIR . 'Presenters/Install/MySqlScript.php');
require_once(ROOT_DIR . 'Presenters/Install/InstallationResult.php');

mysqli_report(MYSQLI_REPORT_OFF);

function fail($message)
{
    fwrite(STDERR, "[lb-db] $message\n");
    exit(1);
}

$config = Configuration::Instance();
$host = $config->GetKey(ConfigKeys::DATABASE_HOSTSPEC);
$name = $config->GetKey(ConfigKeys::DATABASE_NAME);
$user = $config->GetKey(ConfigKeys::DATABASE_USER);
$password = $config->GetKey(ConfigKeys::DATABASE_PASSWORD);

$link = @mysqli_connect($host, $user, $password, $name);
if (!$link) {
    fail("cannot connect to database '$name' on '$host' as '$user': " . mysqli_connect_error());
}

function table_count($link)
{
    $result = mysqli_query($link, 'SHOW TABLES');
    return $result ? mysqli_num_rows($result) : 0;
}

function has_table($link, $table)
{
    $table = mysqli_real_escape_string($link, $table);
    $result = mysqli_query($link, "SHOW TABLES LIKE '$table'");
    return $result && mysqli_num_rows($result) > 0;
}

function report($results)
{
    $ok = true;
    foreach ($results as $result) {
        if ($result instanceof InstallationResultSkipped) {
            continue;
        }
        if (!$result->WasSuccessful()) {
            $ok = false;
            $why = $result->connectionError ? 'cannot connect'
                 : ($result->authError ? 'cannot open the database' : $result->sqlErrorText);
            fwrite(STDERR, '[lb-db] FAILED ' . $result->taskName . ': ' . $why . "\n");
            if ($result->sqlText) {
                fwrite(STDERR, '[lb-db]   statement: ' . substr(trim($result->sqlText), 0, 300) . "\n");
            }
        } else {
            echo '[lb-db] ok ' . $result->taskName . "\n";
        }
    }
    return $ok;
}

$installer = new Installer($user, $password);

switch ($command) {
    case 'status':
        $tables = table_count($link);
        if ($tables === 0) {
            echo "empty\n";
        } elseif (has_table($link, 'layouts') && has_table($link, 'dbversion')) {
            echo 'installed ' . $installer->GetVersion() . "\n";
        } else {
            echo "foreign $tables\n";
        }
        break;

    case 'install':
        // Never install over existing tables: the schema script drops tables it creates.
        if (table_count($link) !== 0) {
            fail("database '$name' is not empty; refusing to install over it");
        }
        $ok = report($installer->InstallFresh(false, false, false));
        if (!$ok) {
            fail('installation failed');
        }
        echo '[lb-db] installed schema version ' . $installer->GetVersion() . "\n";
        if (is_dir(ROOT_DIR . 'tpl_c')) {
            $installer->ClearCachedTemplates();
        }
        break;

    case 'upgrade':
        if (!(has_table($link, 'layouts') && has_table($link, 'dbversion'))) {
            fail("database '$name' does not hold a LibreBooking installation; not upgrading");
        }
        $before = $installer->GetVersion();
        $ok = report($installer->Upgrade());
        if (!$ok) {
            fail('upgrade failed');
        }
        $after = $installer->GetVersion();
        echo $before == $after ? "[lb-db] database is current (version $after)\n"
                                 : "[lb-db] upgraded database from $before to $after\n";
        if ($before != $after && is_dir(ROOT_DIR . 'tpl_c')) {
            $installer->ClearCachedTemplates();
        }
        break;

    default:
        fail('usage: php lb-db.php <status|install|upgrade> [app-root]');
}
