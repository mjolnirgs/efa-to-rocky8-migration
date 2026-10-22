# Rocky Linux Mail Stack — Post-Update Maintenance Script

A maintenance script for self-managed Rocky Linux 8 mail servers that were
migrated from eFa (Email Filter Appliance) or built with the same stack:
MailScanner, MailWatch, SOGo, Z-Push, ClamAV unofficial signatures, and DCC.

Run it after `dnf update && reboot` to keep the components that don't ship
through DNF up to date.

---

## Background

[eFa](https://efa-project.org/) is an open-source mail security appliance that
bundles Postfix, Dovecot, MailScanner, MailWatch, SOGo, Z-Push, ClamAV, and
DCC into a single-server install. When it went EOL, the underlying stack
remained perfectly serviceable — it just lost its turnkey updater.

This script fills that gap. It checks GitHub releases against installed
versions for each component that ships outside the standard RPM repos and
upgrades only what's behind.

---

## Stack

| Component | How it's distributed |
|-----------|----------------------|
| MailScanner | GitHub releases (noarch RPM) |
| MailWatch | GitHub releases (source tarball) |
| Z-Push | GitHub releases (source tarball) |
| ClamAV unofficial sigs | `clamav-unofficial-sigs` package |
| DCC | `/var/dcc/libexec/updatedcc` |
| CPAN modules | `cpan-outdated` + `cpanm` |

---

## Prerequisites

- Rocky Linux 8 (see [Why Rocky 8?](#why-rocky-8))
- The components above installed and working
- `curl`, `rsync`, `patch` — standard, should already be present
- `perl-App-cpanminus` and `App::cpanoutdated` installed:

```bash
dnf install -y perl-App-cpanminus libdb-devel
curl -L https://cpanmin.us | perl - App::cpanoutdated
```

> `libdb-devel` is required for the `DB_File` CPAN module. `db4-devel`
> doesn't exist on Rocky 8 — use `libdb-devel`.

---

## Installation

```bash
curl -o /usr/local/sbin/post-update.sh \
  https://raw.githubusercontent.com/<your-repo>/main/post-update.sh
chmod +x /usr/local/sbin/post-update.sh
```

Edit the configuration block at the top of the script:

```bash
# Path to your SOGo CalDAV/CardDAV patch for Z-Push (leave empty to skip)
ZPUSH_SOGO_PATCH="/usr/local/etc/zpush-sogo.patch"

# MailWatch web root
MAILWATCH_WEBROOT="/var/www/html/mailscanner"

# Z-Push install path
ZPUSH_DIR="/usr/share/z-push"
```

---

## Usage

```bash
# Normal run (as root)
/usr/local/sbin/post-update.sh

# Dry run — shows what would be done without making changes
/usr/local/sbin/post-update.sh --dry-run
```

Typical workflow after a system update:

```bash
dnf update
reboot
# after reboot:
/usr/local/sbin/post-update.sh
```

---

## What it does

### Step 1 — ClamAV unofficial signatures

Runs `clamav-unofficial-sigs.sh --upgrade` and restarts the service. The
unofficial sigs package adds third-party signature databases (Sanesecurity,
MalwarePatrol, etc.) beyond what `freshclam` fetches.

### Step 2 — DCC (Distributed Checksum Clearinghouse)

Runs `/var/dcc/libexec/updatedcc` and reports before/after version. DCC is a
spam-detection system based on bulk-mail checksums; it doesn't ship in any
repo and has its own updater.

Note: `dccproc -V` returns a non-zero exit code. The script uses `|| true`
to prevent `set -e` from treating this as a failure.

### Step 3 — MailScanner

Checks the installed RPM version against the latest GitHub release from
[MailScanner/v5](https://github.com/MailScanner/v5/releases) and upgrades if
behind. The RPM `RELEASE` field includes a dist tag (`.rhel`, `.el8`) that
must be stripped before comparing to GitHub tags — the script handles this.

### Step 4 — MailWatch

Checks the installed version (extracted from `functions.php`, where it's a
string literal returned by `mailwatch_version()` rather than a constant)
against the latest GitHub release from
[mailwatch/MailWatch](https://github.com/mailwatch/MailWatch/releases).

On upgrade, it uses `rsync` to sync new files while explicitly excluding
`conf.php` (your local configuration with database credentials) and
`MailWatchConf.pm` (local Perl config).

### Step 5 — Z-Push

Checks the installed version (from `/usr/share/z-push/version`, a plain-text
file) against the latest GitHub release from
[Z-Hub/Z-Push](https://github.com/Z-Hub/Z-Push/releases). GitHub tags have a
`v` prefix; the version file doesn't — the script strips it before comparing.

On upgrade, `config.php` is excluded from the rsync so your configuration is
preserved. If `ZPUSH_SOGO_PATCH` is set and the file exists, the SOGo
CalDAV/CardDAV patch is re-applied after each upgrade.

### Step 6 — CPAN modules

Runs `cpan-outdated` and pipes any outdated modules to `cpanm`. MailScanner
and MailWatch depend on several Perl modules that ship through CPAN rather
than DNF.

---

## The SOGo CalDAV/CardDAV patch for Z-Push

If you're using Z-Push with the SOGo backend for calendar and contacts sync,
you may need a patch to handle null `getlastmodified` responses from SOGo.
This is tracked as [Z-Hub/Z-Push#276](https://github.com/Z-Hub/Z-Push/issues/276).

Place the patch file at the path set in `ZPUSH_SOGO_PATCH` (default:
`/usr/local/etc/zpush-sogo.patch`). The script re-applies it after each
Z-Push upgrade. Leave `ZPUSH_SOGO_PATCH` empty to skip patching entirely.

---

## Why Rocky 8?

Z-Push's IMAP backend requires `php-imap`, which was dropped from PHP 8.x and
is not available in Rocky 9 / EL9's appstream. This is tracked at
[Z-Hub/Z-Push#169](https://github.com/Z-Hub/Z-Push/issues/169). Until a
replacement backend ships, Rocky 8 (EOL May 2029) is required for full
ActiveSync support.

If all your mobile clients are configured for native CalDAV/CardDAV and you
don't need Z-Push, Rocky 9 works fine for the rest of this stack.

---

## Notes and gotchas

- The MailScanner service name on Rocky 8 is `mailscanner` (lowercase), not
  `MailScanner`. Scripting `systemctl restart MailScanner` will fail silently.
- MailWatch version detection looks for the function body in `functions.php`,
  not a `MAILWATCH_VERSION` constant — that constant doesn't exist.
- Clear your browser cache after a MailWatch upgrade; cached JS/CSS from the
  old version will cause display issues.
- The script runs with `set -euo pipefail`. Any unexpected failure in a step
  increments an error counter and continues to the next step rather than
  aborting entirely.
- GitHub API rate limits: unauthenticated requests are limited to 60/hour per
  IP. If you run this script frequently in CI or from a shared IP, add a
  `GITHUB_TOKEN` header to the `github_latest_version` function.

---

## Related

- [Migrating from eFa to a self-managed Rocky Linux 8 mail stack](https://www.tooleweb.ca/blog/efa-to-rocky-migration/) — the companion blog post covering the full migration
- [MailScanner](https://www.mailscanner.info/)
- [MailWatch](https://github.com/mailwatch/MailWatch)
- [Z-Push](https://github.com/Z-Hub/Z-Push)
- [SOGo](https://www.sogo.nu/)
- [DCC](https://www.dcc-servers.net/dcc/)
- [ClamAV Unofficial Signatures](https://github.com/extremeshok/clamav-unofficial-sigs)

---

## Licence

MIT
