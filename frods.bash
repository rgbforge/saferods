#!/bin/bash
set -e

UNINSTALL=false
JSON_FILE=""
ERROR_COUNT=0
WARNING_COUNT=0
SUCCESS_COUNT=0

track_operation() {
    local operation="$1"
    local status="$2"
    local details="$3"
    case "$status" in
        ("SUCCESS")
            echo "  [SUCCESS] $operation: $details" | tee -a "$LOG_FILE"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            ;;
        ("WARNING")
            echo "  [WARNING] $operation: $details" | tee -a "$LOG_FILE"
            WARNING_COUNT=$((WARNING_COUNT + 1))
            ;;
        ("ERROR")
            echo "  [ERROR] $operation: $details" | tee -a "$LOG_FILE"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            ;;
    esac
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        (-u|--uninstall) UNINSTALL=true; shift ;;
        (-f|--file) JSON_FILE="$2"; shift 2 ;;
        (*) echo "Unknown parameter: $1"; exit 1 ;;
    esac
done

if [ "$UNINSTALL" = true ]; then
    if [ -z "$JSON_FILE" ]; then
        echo "Error: JSON file path must be provided with -f or --file option"
        exit 1
    fi
    if [ ! -f "$JSON_FILE" ]; then
        echo "Error: JSON file not found: $JSON_FILE"
        exit 1
    fi
    UNINSTALL_LOG="/var/log/irods_uninstall_$(date +%Y%m%d_%H%M%S).log"
    touch "$UNINSTALL_LOG"
    echo "Starting uninstallation process at $(date)" | tee -a "$UNINSTALL_LOG"
    echo "Using JSON file: $JSON_FILE" | tee -a "$UNINSTALL_LOG"
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is required for uninstallation." | tee -a "$UNINSTALL_LOG"
        echo "Attempting to install jq..." | tee -a "$UNINSTALL_LOG"
        if dnf install jq; then
            echo "Successfully installed jq." | tee -a "$UNINSTALL_LOG"
        else
            echo "Failed to install jq. Please install it manually and try again." | tee -a "$UNINSTALL_LOG"
            exit 1
        fi
    fi
    if ! jq -e '.packages' "$JSON_FILE" > /dev/null 2>&1; then
        echo "Error: Invalid packages structure in $JSON_FILE" | tee -a "$UNINSTALL_LOG"
        exit 1
    fi
    PACKAGES=$(jq -r '.packages[]' "$JSON_FILE")
    echo "Removing version locks..." | tee -a "$UNINSTALL_LOG"
    for pkg in $PACKAGES; do
        if [ -n "$pkg" ] && dnf versionlock remove "$pkg" 2>/dev/null; then
            echo "  Removed lock for $pkg" | tee -a "$UNINSTALL_LOG"
        else
            echo "  No lock found for $pkg" | tee -a "$UNINSTALL_LOG"
        fi
    done

    IRODS_REPO="/etc/yum.repos.d/renci-irods.yum.repo"
    echo "Removing iRODS repository exclusions..." | tee -a "$UNINSTALL_LOG"
    if [ -f "$IRODS_REPO" ]; then
        if grep -q "^exclude=" "$IRODS_REPO"; then
            sed -i '/^exclude=/d' "$IRODS_REPO"
            echo "  Removed exclusions from $IRODS_REPO" | tee -a "$UNINSTALL_LOG"
        else
            echo "  No exclusions found in $IRODS_REPO" | tee -a "$UNINSTALL_LOG"
        fi
    fi

    echo "Removing package exclusions from dnf.conf..." | tee -a "$UNINSTALL_LOG"

    if grep -q "postgresql-odbc\|python3-jsonschema\|python3-pyodbc\|irods-runtime-4.3.4\|irods-externals\|irods-server-4.3.4\|irods-database-plugin-postgres-4.3.4\|irods-icommands-4.3.4\|irods-rule-engine-plugin-python-4.3.4.0-0" /etc/dnf/dnf.conf; then
        ORIGINAL_LINE=$(grep "^exclude=" /etc/dnf/dnf.conf)
        NEW_LINE=$(echo "$ORIGINAL_LINE" \
            | sed 's/postgresql-odbc-10.03.0000\*//g' \
            | sed 's/python3-jsonschema-2.6.0\*//g' \
            | sed 's/python3-pyodbc-4.0.30\*//g' \
            | sed 's/irods-runtime-4.3.4\*//g' \
            | sed 's/irods-externals-clang-runtime13.0.1-0-1.0-1\.el8.x86_64\*//g' \
            | sed 's/irods-externals-boost-libcxx1.81.0-1-1.0-2\.el8.x86_64\*//g' \
            | sed 's/irods-externals-avro-libcxx1.11.0-3-1.0-1\.el8.x86_64\*//g' \
            | sed 's/irods-externals-fmt-libcxx8.1.1-1-1.0-1\.el8.x86_64\*//g' \
            | sed 's/irods-externals-nanodbc-libcxx2.13.0-2-1.0-1\.el8.x86_64\*//g' \
            | sed 's/irods-externals-spdlog-libcxx1.9.2-2-1.0-1\.el8.x86_64\*//g' \
            | sed 's/irods-externals-zeromq4-1-libcxx4.1.8-1-1.0-2\.el8.x86_64\*//g' \
            | sed 's/irods-server-4.3.4\*//g' \
            | sed 's/irods-database-plugin-postgres-4.3.4\*//g' \
            | sed 's/irods-icommands-4.3.4\*//g' \
            | sed 's/irods-rule-engine-plugin-python-4.3.4.0-0\.el8\+4.3.4\.x86_64\*//g' \
            | sed 's/[ ]\+/ /g' \
            | sed 's/ $//' \
            | sed 's/=[ ]*/=/')
        if [[ "$NEW_LINE" == "exclude=" ]]; then
            sed -i '/^exclude=/d' /etc/dnf/dnf.conf
            echo "  Removed empty exclude line from dnf.conf" | tee -a "$UNINSTALL_LOG"
        else
            sed -i "s|$ORIGINAL_LINE|$NEW_LINE|" /etc/dnf/dnf.conf
            echo "  Updated exclude directive in dnf.conf" | tee -a "$UNINSTALL_LOG"
        fi
    else
        echo "  No matching package exclusions found in dnf.conf" | tee -a "$UNINSTALL_LOG"
    fi

    echo "Removing installed files..." | tee -a "$UNINSTALL_LOG"
    FILE_COUNT=0
    REMOVED_COUNT=0
    MISSING_COUNT=0
    SKIPPED_COUNT=0
    COUNTS_FILE=$(mktemp)
    echo "0 0 0 0" > "$COUNTS_FILE"
    jq -r '.files[]' "$JSON_FILE" | while read -r file; do
        read FILE_COUNT REMOVED_COUNT MISSING_COUNT SKIPPED_COUNT < "$COUNTS_FILE"
        FILE_COUNT=$((FILE_COUNT + 1))
        if [[ ! "$file" == /opt/irods* ]] && [[ ! "$file" == /usr/bin/irods* ]] && [[ ! "$file" == /usr/lib*/irods* ]] && [[ ! "$file" == /usr/include/irods* ]] && [[ ! "$file" == /etc/irods* ]] && [[ ! "$file" == /var/lib/irods* ]] && [[ ! "$file" == */postgresql-odbc* ]] && [[ ! "$file" == */python3-jsonschema* ]] && [[ ! "$file" == */python3-pyodbc* ]]; then
            echo "  SAFETY SKIP: $file (does not match expected paths)" >> "$UNINSTALL_LOG"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            echo "$FILE_COUNT $REMOVED_COUNT $MISSING_COUNT $SKIPPED_COUNT" > "$COUNTS_FILE"
            continue
        fi
        if [ -f "$file" ]; then
            rm -f "$file"
            echo "  Removed: $file" >> "$UNINSTALL_LOG"
            REMOVED_COUNT=$((REMOVED_COUNT + 1))
        else
            echo "  File not found: $file" >> "$UNINSTALL_LOG"
            MISSING_COUNT=$((MISSING_COUNT + 1))
        fi
        echo "$FILE_COUNT $REMOVED_COUNT $MISSING_COUNT $SKIPPED_COUNT" > "$COUNTS_FILE"
    done
    read FILE_COUNT REMOVED_COUNT MISSING_COUNT SKIPPED_COUNT < "$COUNTS_FILE"
    rm -f "$COUNTS_FILE"
    echo "  Total files processed: $FILE_COUNT" | tee -a "$UNINSTALL_LOG"
    echo "  Files successfully removed: $REMOVED_COUNT" | tee -a "$UNINSTALL_LOG"
    echo "  Files not found: $MISSING_COUNT" | tee -a "$UNINSTALL_LOG"
    echo "  Files skipped for safety: $SKIPPED_COUNT" | tee -a "$UNINSTALL_LOG"

    echo "Cleaning up empty directories..." | tee -a "$UNINSTALL_LOG"
    if [ -d "/opt/irods-externals" ]; then
        find "/opt/irods-externals" -type d -empty -delete 2>/dev/null
        echo "  Cleaned up empty directories in /opt/irods-externals" | tee -a "$UNINSTALL_LOG"
        if [ -d "/opt/irods-externals" ] && [ -z "$(ls -A "/opt/irods-externals")" ]; then
            rmdir "/opt/irods-externals"
            echo "  Removed empty /opt/irods-externals directory" | tee -a "$UNINSTALL_LOG"
        fi
    fi
    for base_dir in "/usr/lib/irods" "/usr/include/irods" "/etc/irods" "/var/lib/irods"; do
        if [ -d "$base_dir" ]; then
            find "$base_dir" -type d -empty -delete 2>/dev/null
            echo "  Cleaned up empty directories in $base_dir" | tee -a "$UNINSTALL_LOG"
            if [ -d "$base_dir" ] && [ -z "$(ls -A "$base_dir")" ]; then
                rmdir "$base_dir"
                echo "  Removed empty $base_dir directory" | tee -a "$UNINSTALL_LOG"
            fi
        fi
    done

    echo "Removing packages from RPM database..." | tee -a "$UNINSTALL_LOG"
    for pkg in $PACKAGES; do
        if [ -n "$pkg" ] && rpm -q "$pkg" &>/dev/null; then
            if rpm -e --justdb --nodeps "$pkg"; then
                echo "  Removed $pkg from RPM database" | tee -a "$UNINSTALL_LOG"
            else
                echo "  Failed to remove $pkg from RPM database" | tee -a "$UNINSTALL_LOG"
            fi
        else
            echo "  Package $pkg not found in RPM database" | tee -a "$UNINSTALL_LOG"
        fi
    done

    echo "Verifying RPM database removal..." | tee -a "$UNINSTALL_LOG"
    if ! REMAINING=$(rpm -qa | grep -E 'irods|postgresql-odbc|python3-jsonschema|python3-pyodbc' 2>/dev/null); then
        echo "  Warning: Failed to verify RPM database" | tee -a "$UNINSTALL_LOG"
    elif [ -z "$REMAINING" ]; then
        echo "  All packages successfully removed from RPM database" | tee -a "$UNINSTALL_LOG"
    else
        echo "  Warning: Some packages still remain in RPM database:" | tee -a "$UNINSTALL_LOG"
        echo "$REMAINING" | sed 's/^/    /' | tee -a "$UNINSTALL_LOG"
    fi
    echo "Uninstallation completed at $(date)" | tee -a "$UNINSTALL_LOG"
    echo "Full uninstallation log saved to $UNINSTALL_LOG" | tee
    exit 0
fi

TEMPDIR=$(mktemp -d)
if [ ! -d "$TEMPDIR" ]; then
    echo "Error: Failed to create temporary directory"
    exit 1
fi

trap 'rm -rf "$TEMPDIR"; echo "Cleaned up temporary files"; exit' EXIT INT TERM
cd "$TEMPDIR" || { echo "Error: Failed to change to temporary directory"; exit 1; }
LOG_FILE="/var/log/irods_install_$(date +%Y%m%d_%H%M%S).log"
touch "$LOG_FILE" || { echo "Error: Failed to create log file"; exit 1; }
echo "Installation started at $(date)" | tee -a "$LOG_FILE"
JSON_FILE="/var/log/irods_install_$(date +%Y%m%d_%H%M%S).json"
echo '{"packages":[],"files":[]}' > "$JSON_FILE" || { echo "Error: Failed to create JSON file"; exit 1; }

PACKAGES=(
    "postgresql-odbc-10.03.0000-3.el8_6.x86_64"
    "python3-jsonschema-2.6.0-4.el8.noarch"
    "python3-pyodbc-4.0.30-2.el8.x86_64"
    "irods-runtime-4.3.4-0.el8.x86_64"
    "irods-externals-clang-runtime13.0.1-0-1.0-1.el8.x86_64"
    "irods-externals-boost-libcxx1.81.0-1-1.0-2.el8.x86_64"
    "irods-externals-avro-libcxx1.11.0-3-1.0-1.el8.x86_64"
    "irods-externals-fmt-libcxx8.1.1-1-1.0-1.el8.x86_64"
    "irods-externals-nanodbc-libcxx2.13.0-2-1.0-1.el8.x86_64"
    "irods-externals-spdlog-libcxx1.9.2-2-1.0-1.el8.x86_64"
    "irods-externals-zeromq4-1-libcxx4.1.8-1-1.0-2.el8.x86_64"
    "irods-server-4.3.4-0.el8.x86_64"
    "irods-database-plugin-postgres-4.3.4-0.el8.x86_64"
    "irods-icommands-4.3.4-0.el8.x86_64"
    "irods-rule-engine-plugin-python-4.3.4.0-0.el8+4.3.4.x86_64"
)

if ! command -v jq &> /dev/null; then
    track_operation "jq check" "WARNING" "jq is not installed. Uninstallation will not be possible without installing jq later."
    echo "Installing jq for JSON processing..." | tee -a "$LOG_FILE"
    if dnf install jq; then
        track_operation "jq installation" "SUCCESS" "Successfully installed jq"
    else
        track_operation "jq installation" "ERROR" "Failed to install jq. Please install it manually for uninstallation."
    fi
else
    track_operation "jq check" "SUCCESS" "jq is already installed"
fi

echo "Installing versionlock ..." | tee -a "$LOG_FILE"
if dnf install python3-dnf-plugins-extras-versionlock; then
    track_operation "versionlock installation" "SUCCESS" "Successfully installed versionlock plugin"
else
    track_operation "versionlock installation" "ERROR" "Failed to install versionlock plugin"
fi

echo "Downloading packages..." | tee -a "$LOG_FILE"
if dnf download \
    "postgresql-odbc-10.03.0000-3.el8_6.x86_64" \
    "python3-jsonschema-2.6.0-4.el8.noarch" \
    "python3-pyodbc-4.0.30-2.el8.x86_64" \
    "irods-runtime-4.3.4-0.el8.x86_64" \
    "irods-externals-clang-runtime13.0.1-0-1.0-1.el8.x86_64" \
    "irods-externals-boost-libcxx1.81.0-1-1.0-2.el8.x86_64" \
    "irods-externals-avro-libcxx1.11.0-3-1.0-1.el8.x86_64" \
    "irods-externals-fmt-libcxx8.1.1-1-1.0-1.el8.x86_64" \
    "irods-externals-nanodbc-libcxx2.13.0-2-1.0-1.el8.x86_64" \
    "irods-externals-spdlog-libcxx1.9.2-2-1.0-1.el8.x86_64" \
    "irods-externals-zeromq4-1-libcxx4.1.8-1-1.0-2.el8.x86_64" \
    "irods-server-4.3.4-0.el8.x86_64" \
    "irods-database-plugin-postgres-4.3.4-0.el8.x86_64" \
    "irods-icommands-4.3.4-0.el8.x86_64" \
    "irods-rule-engine-plugin-python-4.3.4.0-0.el8+4.3.4.x86_64"
then
    track_operation "Package download" "SUCCESS" "Downloaded all packages"
else
    track_operation "Package download" "ERROR" "Failed to download one or more packages"
fi

for pkg in "${PACKAGES[@]}"; do
    pkg_name="${pkg%.x86_64}"
    pkg_name="${pkg_name%.noarch}"
    if rpm -q "$pkg_name" &>/dev/null; then
        track_operation "Package check" "WARNING" "$pkg already installed"
        continue
    fi
    rpm_file=$(find . -name "$pkg.rpm")
    if [ -z "$rpm_file" ]; then
        track_operation "Package file" "ERROR" "Can't find $pkg.rpm"
        continue
    else
        track_operation "Package file" "SUCCESS" "Found $pkg.rpm"
    fi
    echo "Installing $pkg via CPIO..." | tee -a "$LOG_FILE"
    mkdir -p "extracted_$pkg_name"
    cd "extracted_$pkg_name"
    if rpm2cpio "../$rpm_file" | cpio -idm; then
        track_operation "Package extraction" "SUCCESS" "Extracted $pkg"
    else
        track_operation "Package extraction" "ERROR" "Failed to extract $pkg"
        cd "$TEMPDIR"
        continue
    fi
    if [[ "$pkg" == *"irods-externals"* ]]; then
        if [ -d "./opt/irods-externals" ]; then
            mkdir -p /opt/irods-externals
            echo "  Copying files to /opt/irods-externals/" | tee -a "$LOG_FILE"
            file_count=0
            success_count=0
            error_count=0
            find "./opt/irods-externals" -type f | while read -r file; do
                target_file="/${file:2}"
                target_dir=$(dirname "$target_file")
                mkdir -p "$target_dir"
                if cp "$file" "$target_file"; then
                    echo "    $target_file" >> "$LOG_FILE"
                    success_count=$((success_count + 1))
                    jq --arg file "$target_file" '.files += [$file]' "$JSON_FILE" > "${JSON_FILE}.tmp" && mv "${JSON_FILE}.tmp" "$JSON_FILE"
                else
                    echo "    Failed to copy: $file to $target_file" >> "$LOG_FILE"
                    error_count=$((error_count + 1))
                fi
                file_count=$((file_count + 1))
            done
            track_operation "File copying" "SUCCESS" "Copied $success_count externals files (failed: $error_count)"
        fi
    else
        echo "  Copying files to system locations:" | tee -a "$LOG_FILE"
        file_count=0
        success_count=0
        error_count=0
        for dir in usr etc opt var; do
            if [ -d "./$dir" ]; then
                echo "  - Found /$dir directory, copying contents" | tee -a "$LOG_FILE"
                find "./$dir" -type f | while read -r file; do
                    target_file="/${file:2}"
                    target_dir=$(dirname "$target_file")
                    mkdir -p "$target_dir"
                    if cp "$file" "$target_file"; then
                        echo "    $target_file" >> "$LOG_FILE"
                        success_count=$((success_count + 1))
                        jq --arg file "$target_file" '.files += [$file]' "$JSON_FILE" > "${JSON_FILE}.tmp" && mv "${JSON_FILE}.tmp" "$JSON_FILE"
                    else
                        echo "    Failed to copy: $file to $target_file" >> "$LOG_FILE"
                        error_count=$((error_count + 1))
                    fi
                    file_count=$((file_count + 1))
                done
            fi
        done
        track_operation "File copying" "SUCCESS" "Copied $success_count files (failed: $error_count)"
    fi
    if [[ "$pkg" == *"irods-server"* ]]; then
        echo "  Setting ownership and permissions for iRODS server files..." | tee -a "$LOG_FILE"
        if [ -d "/var/lib/irods" ]; then
            if chown -R irods:irods /var/lib/irods; then
                track_operation "Permissions" "SUCCESS" "Set ownership for /var/lib/irods"
            else
                track_operation "Permissions" "ERROR" "Failed to set ownership for /var/lib/irods"
            fi
        fi
        if [ -d "/etc/irods" ]; then
            if chown -R irods:irods /etc/irods && chmod 770 /etc/irods; then
                track_operation "Permissions" "SUCCESS" "Set ownership and permissions for /etc/irods"
            else
                track_operation "Permissions" "ERROR" "Failed to set ownership and permissions for /etc/irods"
            fi
        fi
        if [ -d "/usr/bin" ]; then
            if chmod 755 /usr/bin/irods* 2>/dev/null; then
                track_operation "Permissions" "SUCCESS" "Set executable permissions for iRODS binaries"
            else
                track_operation "Permissions" "WARNING" "No iRODS binaries found in /usr/bin or permission setting failed"
            fi
        fi
        if [ -f "/etc/irods/server_config.json" ]; then
            if chmod 670 /etc/irods/server_config.json; then
                track_operation "Permissions" "SUCCESS" "Set group-writable permissions for server_config.json"
            else
                track_operation "Permissions" "ERROR" "Failed to set permissions for server_config.json"
            fi
        fi
    fi
    if [[ "$pkg" == *"irods-icommands"* ]]; then
        echo "  Setting permissions for iCommands..." | tee -a "$LOG_FILE"
        if find /usr/bin -name "i*" -type f -exec chmod 755 {} \; 2>/dev/null; then
            track_operation "Permissions" "SUCCESS" "Set executable permissions for iCommands"
        else
            track_operation "Permissions" "WARNING" "No iCommands found in /usr/bin or permission setting failed"
        fi
    fi
    cd "$TEMPDIR"
    echo "  Registering $pkg in RPM database" | tee -a "$LOG_FILE"
    if rpm --nodeps --justdb -i "$rpm_file"; then
        track_operation "RPM database" "SUCCESS" "Registered $pkg in RPM database"
    else
        track_operation "RPM database" "ERROR" "Failed to register $pkg in RPM database"
    fi
    jq --arg pkg "$pkg_name" '.packages += [$pkg]' "$JSON_FILE" > "${JSON_FILE}.tmp" && mv "${JSON_FILE}.tmp" "$JSON_FILE"
    echo "Completed CPIO installation of $pkg" | tee -a "$LOG_FILE"
    echo "------------------------------------------------" | tee -a "$LOG_FILE"
done

echo "Locking packages..." | tee -a "$LOG_FILE"
lock_success=0
lock_failure=0
for pkg in "${PACKAGES[@]}"; do
    pkg_name="${pkg%.x86_64}"
    pkg_name="${pkg_name%.noarch}"
    if dnf versionlock add "$pkg_name"; then
        echo "  Locked $pkg_name" | tee -a "$LOG_FILE"
        lock_success=$((lock_success + 1))
    else
        echo "  Failed to lock $pkg_name" | tee -a "$LOG_FILE"
        lock_failure=$((lock_failure + 1))
    fi
done
track_operation "Package locking" "SUCCESS" "Locked $lock_success packages (failed: $lock_failure)"

echo "Adding exclusions to iRODS repository configuration..." | tee -a "$LOG_FILE"
IRODS_REPO="/etc/yum.repos.d/renci-irods.yum.repo"
IRODS_EXCLUSIONS="irods-runtime-4.3.4 irods-externals-clang-runtime13.0.1-0-1.0-1 irods-externals-boost-libcxx1.81.0-1-1.0-2 irods-externals-avro-libcxx1.11.0-3-1.0-1 irods-externals-fmt-libcxx8.1.1-1-1.0-1 irods-externals-nanodbc-libcxx2.13.0-2-1.0-1 irods-externals-spdlog-libcxx1.9.2-2-1.0-1 irods-externals-zeromq4-1-libcxx4.1.8-1-1.0-2 irods-server-4.3.4 irods-database-plugin-postgres-4.3.4 irods-icommands-4.3.4 irods-rule-engine-plugin-python-4.3.4.0-0"
if [ -f "$IRODS_REPO" ]; then
    if grep -q "^exclude=" "$IRODS_REPO"; then
        sed -i "s|^exclude=.*|exclude=$IRODS_EXCLUSIONS|" "$IRODS_REPO"
        track_operation "Repository configuration" "SUCCESS" "Updated existing exclude directive in $IRODS_REPO"
    else
        sed -i "/^\[renci-irods\]/a exclude=$IRODS_EXCLUSIONS" "$IRODS_REPO"
        track_operation "Repository configuration" "SUCCESS" "Added exclude directive to $IRODS_REPO"
    fi
else
    track_operation "Repository configuration" "WARNING" "iRODS repository configuration not found at $IRODS_REPO"
fi

SUPPORT_EXCLUSIONS="postgresql-odbc-10.03.0000* python3-jsonschema-2.6.0* python3-pyodbc-4.0.30*"
IRODS_EXCLUSIONS_WILDCARDS="irods-runtime-4.3.4* irods-externals-clang-runtime13.0.1-0-1.0-1.el8.x86_64* irods-externals-boost-libcxx1.81.0-1-1.0-2.el8.x86_64* irods-externals-avro-libcxx1.11.0-3-1.0-1.el8.x86_64* irods-externals-fmt-libcxx8.1.1-1-1.0-1.el8.x86_64* irods-externals-nanodbc-libcxx2.13.0-2-1.0-1.el8.x86_64* irods-externals-spdlog-libcxx1.9.2-2-1.0-1.el8.x86_64* irods-externals-zeromq4-1-libcxx4.1.8-1-1.0-2.el8.x86_64* irods-server-4.3.4* irods-database-plugin-postgres-4.3.4* irods-icommands-4.3.4* irods-rule-engine-plugin-python-4.3.4.0-0.el8+4.3.4.x86_64*"
ALL_EXCLUSIONS="$SUPPORT_EXCLUSIONS $IRODS_EXCLUSIONS_WILDCARDS"

echo "Adding exclusions to dnf.conf..." | tee -a "$LOG_FILE"
if grep -q "^exclude=" /etc/dnf/dnf.conf; then
    if ! grep -q "postgresql-odbc\|python3-jsonschema\|python3-pyodbc\|irods-runtime-4.3.4\|irods-externals\|irods-server-4.3.4\|irods-database-plugin-postgres-4.3.4\|irods-icommands-4.3.4\|irods-rule-engine-plugin-python-4.3.4.0-0" /etc/dnf/dnf.conf; then
        sed -i "s|^exclude=.*|& $ALL_EXCLUSIONS|" /etc/dnf/dnf.conf
        track_operation "DNF configuration" "SUCCESS" "Added iRODS + supporting package exclusions to existing exclude line in dnf.conf"
    else
        track_operation "DNF configuration" "WARNING" "Exclusions already exist in dnf.conf"
    fi
else
    echo "exclude=$ALL_EXCLUSIONS" >> /etc/dnf/dnf.conf
    track_operation "DNF configuration" "SUCCESS" "Added new exclude line with iRODS + supporting packages to dnf.conf"
fi

cd /
echo "Downloaded package files retained in $TEMPDIR" | tee -a "$LOG_FILE"
echo "Verifying installation..." | tee -a "$LOG_FILE"
INSTALLED_PACKAGES=$(rpm -qa | grep -E 'irods|postgres|python3-json|python3-pyodbc')
echo "$INSTALLED_PACKAGES" | tee -a "$LOG_FILE"
echo "Installation Summary:" | tee -a "$LOG_FILE"
echo "  Successful operations: $SUCCESS_COUNT" | tee -a "$LOG_FILE"
echo "  Warnings: $WARNING_COUNT" | tee -a "$LOG_FILE"
echo "  Errors: $ERROR_COUNT" | tee -a "$LOG_FILE"

if [ $ERROR_COUNT -gt 0 ]; then
    echo "[WARNING] Installation completed with $ERROR_COUNT errors. Review the log at $LOG_FILE" | tee
else
    echo "[SUCCESS] Installation completed successfully!" | tee
fi

echo "Full installation log saved to $LOG_FILE" | tee
echo "JSON uninstall file created at $JSON_FILE" | tee
echo "To uninstall, run: $0 --uninstall -f $JSON_FILE" | tee
