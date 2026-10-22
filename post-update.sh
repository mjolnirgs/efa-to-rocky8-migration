#!/bin/bash
# post-update.sh - Post DNF update maintenance script for Rocky Linux 8 mail servers
# running MailScanner, MailWatch, SOGo, Z-Push, ClamAV unofficial sigs, and DCC.
#
# Run after: dnf update && reboot
# Usage: post-update.sh [--dry-run]
#
# Place in /usr/local/sbin/post-update.sh and make executable.

set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# --------------------------------------------------------
# Configuration — adjust to match your installation
# --------------------------------------------------------

# Path to your SOGo CalDAV/CardDAV patch for Z-Push (leave empty to skip)
ZPUSH_SOGO_PATCH="/usr/local/etc/zpush-sogo.patch"

# MailWatch web root
MAILWATCH_WEBROOT="/var/www/html/mailscanner"

# Z-Push install path
ZPUSH_DIR="/usr/share/z-push"

# --------------------------------------------------------

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
dry()     { echo -e "${YELLOW}[DRY-RUN]${NC} $*"; }

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        dry "$*"
    else
        eval "$*"
    fi
}

# Return the latest release tag for a GitHub repo (owner/repo), stripping leading 'v'
github_latest_version() {
    curl -sf "https://api.github.com/repos/$1/releases/latest" \
        | grep '"tag_name"' \
        | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/'
}

echo ""
echo "========================================================"
echo "  Rocky Linux Mail Stack - Post-Update Maintenance"
echo "  $(date)"
echo "========================================================"
echo ""

ERRORS=0

# --------------------------------------------------------
# 1. ClamAV Unofficial Signatures
# --------------------------------------------------------
log "Step 1/6: ClamAV Unofficial Signatures"
if run "clamav-unofficial-sigs.sh --upgrade"; then
    run "systemctl restart clamav-unofficial-sigs"
    success "clamav-unofficial-sigs updated and restarted"
else
    error "clamav-unofficial-sigs update failed"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# --------------------------------------------------------
# 2. DCC (Distributed Checksum Clearinghouse)
# --------------------------------------------------------
log "Step 2/6: DCC"

# Note: dccproc -V returns non-zero; || true prevents set -e from exiting
BEFORE=$(/usr/bin/dccproc -V 2>&1 | head -1 || true)
if run "/var/dcc/libexec/updatedcc"; then
    AFTER=$(/usr/bin/dccproc -V 2>&1 | head -1 || true)
    if [[ "$BEFORE" != "$AFTER" ]]; then
        success "DCC updated: $BEFORE -> $AFTER"
    else
        success "DCC is current: $AFTER"
    fi
else
    error "DCC update failed"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# --------------------------------------------------------
# 3. MailScanner
# --------------------------------------------------------
log "Step 3/6: MailScanner"

# Strip the dist tag (.rhel, .el8, etc.) from the RPM RELEASE field before
# comparing to GitHub tags, e.g. 5.5.3-2.rhel -> 5.5.3-2
CURRENT_MS=$(rpm -q MailScanner --queryformat '%{VERSION}-%{RELEASE}' 2>/dev/null \
    | sed 's/\.[a-z].*$//' || echo "unknown")
LATEST_MS=$(github_latest_version "MailScanner/v5" 2>/dev/null || echo "unknown")

echo "  Current: $CURRENT_MS"
echo "  Latest:  $LATEST_MS"

if [[ "$CURRENT_MS" == "unknown" || "$LATEST_MS" == "unknown" ]]; then
    warn "Could not determine MailScanner versions — check manually"
    ERRORS=$((ERRORS + 1))
elif [[ "$CURRENT_MS" == "$LATEST_MS" ]]; then
    success "MailScanner is current ($CURRENT_MS)"
else
    log "MailScanner upgrade available: $CURRENT_MS -> $LATEST_MS"
    MS_URL="https://github.com/MailScanner/v5/releases/download/${LATEST_MS}/MailScanner-${LATEST_MS}.noarch.rpm"
    if run "dnf install -y '$MS_URL'"; then
        # Note: service name is 'mailscanner' (lowercase) on Rocky/RHEL
        run "systemctl restart mailscanner"
        success "MailScanner upgraded to $LATEST_MS and restarted"
    else
        error "MailScanner upgrade failed — install manually from:"
        error "  $MS_URL"
        ERRORS=$((ERRORS + 1))
    fi
fi
echo ""

# --------------------------------------------------------
# 4. MailWatch
# --------------------------------------------------------
log "Step 4/6: MailWatch"

# MailWatch version is a string literal returned by mailwatch_version() in
# functions.php — there is no MAILWATCH_VERSION constant to grep for
CURRENT_MW=$(grep -A2 'function mailwatch_version' "${MAILWATCH_WEBROOT}/functions.php" 2>/dev/null \
    | grep -oP "[\d]+\.[\d]+\.[\d]+" | head -1 || echo "unknown")
LATEST_MW=$(github_latest_version "mailwatch/MailWatch" 2>/dev/null || echo "unknown")

echo "  Current: $CURRENT_MW"
echo "  Latest:  $LATEST_MW"

if [[ "$CURRENT_MW" == "unknown" || "$LATEST_MW" == "unknown" ]]; then
    warn "Could not determine MailWatch versions — check manually"
    warn "  https://github.com/mailwatch/MailWatch/releases"
    ERRORS=$((ERRORS + 1))
elif [[ "$CURRENT_MW" == "$LATEST_MW" ]]; then
    success "MailWatch is current ($CURRENT_MW)"
else
    log "MailWatch upgrade available: $CURRENT_MW -> $LATEST_MW"
    MW_URL="https://github.com/mailwatch/MailWatch/archive/refs/tags/v${LATEST_MW}.tar.gz"
    MW_TMP=$(mktemp -d)

    log "Downloading MailWatch $LATEST_MW..."
    if run "curl -sL '$MW_URL' -o '$MW_TMP/mailwatch.tar.gz'"; then
        run "tar xzf '$MW_TMP/mailwatch.tar.gz' -C '$MW_TMP'"
        MW_DIR="$MW_TMP/MailWatch-${LATEST_MW}"

        log "Syncing MailWatch files..."
        # Exclude conf.php (your local config) and MailWatchConf.pm (local Perl config)
        run "rsync -av --ignore-times --exclude='conf.php' '$MW_DIR/mailscanner/' '${MAILWATCH_WEBROOT}/'"
        run "rsync -av --ignore-times --exclude='MailWatchConf.pm' '$MW_DIR/MailScanner_perl_scripts/'*.pm /usr/share/MailScanner/perl/custom/"
        run "rsync -av --ignore-times '$MW_DIR/tools/' /usr/bin/mailwatch/tools/"

        run "find /usr/bin/mailwatch/tools -name '*.sh' -exec chmod +x {} \;"
        run "find /usr/bin/mailwatch/tools -name '*.php' -exec chmod +x {} \;"

        run "systemctl restart mailscanner php-fpm"
        run "rm -rf '$MW_TMP'"
        success "MailWatch upgraded to $LATEST_MW"
        warn "Clear your browser cache after a MailWatch upgrade"
    else
        error "MailWatch download failed — upgrade manually from:"
        error "  https://github.com/mailwatch/MailWatch/releases"
        ERRORS=$((ERRORS + 1))
    fi
fi
echo ""

# --------------------------------------------------------
# 5. Z-Push
# --------------------------------------------------------
log "Step 5/6: Z-Push"

# Z-Push version is stored as plain text in ${ZPUSH_DIR}/version — not a PHP constant
CURRENT_ZP=$(cat "${ZPUSH_DIR}/version" 2>/dev/null | tr -d '[:space:]' || echo "unknown")
# GitHub tags have a 'v' prefix; the version file does not — strip it
LATEST_ZP=$(github_latest_version "Z-Hub/Z-Push" 2>/dev/null | sed 's/^v//' || echo "unknown")

echo "  Current: $CURRENT_ZP"
echo "  Latest:  $LATEST_ZP"

if [[ "$CURRENT_ZP" == "unknown" || "$LATEST_ZP" == "unknown" ]]; then
    warn "Could not determine Z-Push versions — check manually"
    warn "  https://github.com/Z-Hub/Z-Push/releases"
    ERRORS=$((ERRORS + 1))
elif [[ "$CURRENT_ZP" == "$LATEST_ZP" ]]; then
    success "Z-Push is current ($CURRENT_ZP)"
else
    log "Z-Push upgrade available: $CURRENT_ZP -> $LATEST_ZP"
    ZP_URL="https://github.com/Z-Hub/Z-Push/archive/refs/tags/${LATEST_ZP}.tar.gz"
    ZP_TMP=$(mktemp -d)

    log "Downloading Z-Push $LATEST_ZP..."
    if run "curl -sL '$ZP_URL' -o '$ZP_TMP/zpush.tar.gz'"; then
        run "tar xzf '$ZP_TMP/zpush.tar.gz' -C '$ZP_TMP'"
        ZP_DIR=$(find "$ZP_TMP" -maxdepth 1 -type d -name "Z-Push*" | head -1)

        log "Syncing Z-Push files..."
        run "rsync -avp --ignore-times --exclude='config.php' --exclude='*config.php' --delete '$ZP_DIR/src/' '${ZPUSH_DIR}/'"

        if [[ -n "$ZPUSH_SOGO_PATCH" && -f "$ZPUSH_SOGO_PATCH" ]]; then
            log "Applying SOGo CalDAV/CardDAV patch..."
            run "patch -p1 -d '${ZPUSH_DIR}' < '$ZPUSH_SOGO_PATCH'"
            run "php -r 'opcache_reset();'"
            run "systemctl restart httpd php-fpm"
            success "SOGo CalDAV/CardDAV patch applied"
        elif [[ -n "$ZPUSH_SOGO_PATCH" ]]; then
            error "Patch file not found: $ZPUSH_SOGO_PATCH"
            error "  Place the patch file there or clear ZPUSH_SOGO_PATCH in the config section"
            ERRORS=$((ERRORS + 1))
        fi

        run "rm -rf '$ZP_TMP'"
        success "Z-Push upgraded to $LATEST_ZP"
    else
        error "Z-Push download failed — upgrade manually from:"
        error "  https://github.com/Z-Hub/Z-Push/releases"
        ERRORS=$((ERRORS + 1))
    fi
fi
echo ""

# --------------------------------------------------------
# 6. CPAN Modules
# --------------------------------------------------------
log "Step 6/6: CPAN Modules"
OUTDATED=$(cpan-outdated 2>/dev/null || true)
if [[ -z "$OUTDATED" ]]; then
    success "All CPAN modules are current"
else
    log "Outdated CPAN modules found:"
    echo "$OUTDATED"
    if run "cpan-outdated | cpanm"; then
        success "CPAN modules updated"
    else
        error "Some CPAN modules failed to update — review output above"
        ERRORS=$((ERRORS + 1))
    fi
fi
echo ""

# --------------------------------------------------------
# Summary
# --------------------------------------------------------
echo "========================================================"
if [[ $ERRORS -eq 0 ]]; then
    success "All steps completed successfully"
else
    error "$ERRORS step(s) had errors — review output above"
fi
echo "========================================================"
echo ""
