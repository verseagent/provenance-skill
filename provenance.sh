#!/bin/bash

# Provenance Skill - Content origin tracking for AI agents
# Track where information comes from, manage trust, quarantine suspicious content

set -e

PROVENANCE_DIR="${PROVENANCE_DIR:-$HOME/.provenance}"
DB_PATH="$PROVENANCE_DIR/trust.db"

# Ensure provenance directory exists
mkdir -p "$PROVENANCE_DIR"

# Initialize database if needed
init_db() {
    if [ ! -f "$DB_PATH" ]; then
        sqlite3 "$DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS content (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    trust_level TEXT NOT NULL DEFAULT 'unknown',
    marked_at INTEGER NOT NULL,
    custody_chain TEXT DEFAULT '[]'
);
CREATE INDEX IF NOT EXISTS idx_source ON content(source);
CREATE INDEX IF NOT EXISTS idx_trust ON content(trust_level);

CREATE TABLE IF NOT EXISTS policies (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pattern TEXT NOT NULL UNIQUE,
    trust_level TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS quarantine (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    content_id TEXT NOT NULL,
    reason TEXT,
    quarantined_at INTEGER NOT NULL,
    FOREIGN KEY (content_id) REFERENCES content(id)
);
CREATE INDEX IF NOT EXISTS idx_quarantine_content ON quarantine(content_id);

CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    action TEXT NOT NULL,
    content_id TEXT,
    details TEXT,
    timestamp INTEGER NOT NULL
);
SQL
        echo "Initialized provenance database at $DB_PATH"
    fi
}

# Escape single quotes for SQL
sql_escape() {
    echo "${1//\'/\'\'}"
}

# Log an audit event
log_audit() {
    local action="$1"
    local content_id="$2"
    local details="$3"
    local now=$(date +%s)

    sqlite3 "$DB_PATH" "INSERT INTO audit_log (action, content_id, details, timestamp) VALUES ('$(sql_escape "$action")', '$(sql_escape "$content_id")', '$(sql_escape "$details")', $now)"
}

# Mark content with source and trust level
cmd_mark_source() {
    local id="$1"
    local source="$2"
    local trust_level="${3:-unknown}"

    if [ -z "$id" ] || [ -z "$source" ]; then
        echo "Usage: /mark-source <id> <source> [trust-level]"
        echo "Trust levels: trusted, untrusted, unknown (default: unknown)"
        echo ""
        echo "Examples:"
        echo "  /mark-source msg-123 \"moltbook:@randomagent\" untrusted"
        echo "  /mark-source doc-456 \"internal:collaborator\" trusted"
        return 1
    fi

    # Validate trust level
    case "$trust_level" in
        trusted|untrusted|unknown) ;;
        *)
            echo "Error: Invalid trust level '$trust_level'"
            echo "Valid levels: trusted, untrusted, unknown"
            return 1
            ;;
    esac

    local now=$(date +%s)
    local esc_id=$(sql_escape "$id")
    local esc_source=$(sql_escape "$source")

    # Check if ID already exists
    local existing=$(sqlite3 "$DB_PATH" "SELECT id FROM content WHERE id = '$esc_id' LIMIT 1")

    if [ -n "$existing" ]; then
        # Update existing, append to custody chain
        local old_chain=$(sqlite3 "$DB_PATH" "SELECT custody_chain FROM content WHERE id = '$esc_id'")
        local new_entry="{\"source\":\"$esc_source\",\"trust\":\"$trust_level\",\"at\":$now}"

        # Append to chain (simple approach - works for JSON arrays)
        if [ "$old_chain" = "[]" ]; then
            local new_chain="[$new_entry]"
        else
            local new_chain="${old_chain%]}, $new_entry]"
        fi

        sqlite3 "$DB_PATH" "UPDATE content SET source = '$esc_source', trust_level = '$trust_level', marked_at = $now, custody_chain = '$(sql_escape "$new_chain")' WHERE id = '$esc_id'"
        echo "Updated provenance for '$id' (source: $source, trust: $trust_level)"
    else
        sqlite3 "$DB_PATH" "INSERT INTO content (id, source, trust_level, marked_at, custody_chain) VALUES ('$esc_id', '$esc_source', '$trust_level', $now, '[{\"source\":\"$esc_source\",\"trust\":\"$trust_level\",\"at\":$now}]')"
        echo "Marked provenance for '$id' (source: $source, trust: $trust_level)"
    fi

    # Apply any matching policies
    apply_policies "$id" "$source"

    log_audit "mark_source" "$id" "source=$source, trust=$trust_level"
}

# Apply trust policies to content
apply_policies() {
    local id="$1"
    local source="$2"
    local esc_id=$(sql_escape "$id")

    # Get all policies and check for matches
    local policies=$(sqlite3 -separator '|' "$DB_PATH" "SELECT pattern, trust_level FROM policies")

    while IFS='|' read -r pattern trust; do
        [ -z "$pattern" ] && continue

        # Simple glob matching using bash
        if [[ "$source" == $pattern ]]; then
            sqlite3 "$DB_PATH" "UPDATE content SET trust_level = '$trust' WHERE id = '$esc_id'"
            echo "  Applied policy: $pattern -> $trust"
            log_audit "policy_applied" "$id" "pattern=$pattern, trust=$trust"
            return
        fi
    done <<< "$policies"
}

# Check provenance of content
cmd_check_provenance() {
    local id="$1"

    if [ -z "$id" ]; then
        echo "Usage: /check-provenance <id>"
        return 1
    fi

    local esc_id=$(sql_escape "$id")
    local result=$(sqlite3 -separator '|' "$DB_PATH" "SELECT source, trust_level, datetime(marked_at, 'unixepoch'), custody_chain FROM content WHERE id = '$esc_id'")

    if [ -z "$result" ]; then
        echo "No provenance record found for '$id'"
        return 1
    fi

    IFS='|' read -r source trust marked_at custody_chain <<< "$result"

    echo "=== Provenance for '$id' ==="
    echo ""
    echo "Source: $source"
    echo "Trust level: $trust"
    echo "Last marked: $marked_at"
    echo ""
    echo "Custody chain:"
    echo "$custody_chain" | jq -r '.[] | "  - \(.source) (\(.trust)) at \(.at | todate)"' 2>/dev/null || echo "  $custody_chain"

    # Check if quarantined
    local qcount=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM quarantine WHERE content_id = '$esc_id'")
    if [ "$qcount" -gt 0 ]; then
        echo ""
        echo "WARNING: This content is quarantined"
        sqlite3 "$DB_PATH" "SELECT '  Reason: ' || reason || ' (at ' || datetime(quarantined_at, 'unixepoch') || ')' FROM quarantine WHERE content_id = '$esc_id'"
    fi
}

# Trust policy management
cmd_trust_policy() {
    local action="$1"
    shift

    case "$action" in
        add)
            local pattern="$1"
            local trust_level="$2"

            if [ -z "$pattern" ] || [ -z "$trust_level" ]; then
                echo "Usage: /trust-policy add <pattern> <trust-level>"
                echo ""
                echo "Patterns use glob matching. Examples:"
                echo "  internal:*     - All internal sources"
                echo "  moltbook:*     - All Moltbook sources"
                echo "  api:weather*   - Weather API sources"
                return 1
            fi

            # Validate trust level
            case "$trust_level" in
                trusted|untrusted|unknown) ;;
                *)
                    echo "Error: Invalid trust level '$trust_level'"
                    return 1
                    ;;
            esac

            local now=$(date +%s)
            local esc_pattern=$(sql_escape "$pattern")

            # Check if pattern already exists
            local existing=$(sqlite3 "$DB_PATH" "SELECT id FROM policies WHERE pattern = '$esc_pattern' LIMIT 1")

            if [ -n "$existing" ]; then
                sqlite3 "$DB_PATH" "UPDATE policies SET trust_level = '$trust_level' WHERE pattern = '$esc_pattern'"
                echo "Updated policy: $pattern -> $trust_level"
            else
                sqlite3 "$DB_PATH" "INSERT INTO policies (pattern, trust_level, created_at) VALUES ('$esc_pattern', '$trust_level', $now)"
                echo "Added policy: $pattern -> $trust_level"
            fi

            log_audit "policy_add" "" "pattern=$pattern, trust=$trust_level"
            ;;

        remove)
            local pattern="$1"

            if [ -z "$pattern" ]; then
                echo "Usage: /trust-policy remove <pattern>"
                return 1
            fi

            local esc_pattern=$(sql_escape "$pattern")
            local count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM policies WHERE pattern = '$esc_pattern'")

            if [ "$count" -eq 0 ]; then
                echo "No policy found matching: $pattern"
                return 1
            fi

            sqlite3 "$DB_PATH" "DELETE FROM policies WHERE pattern = '$esc_pattern'"
            echo "Removed policy: $pattern"

            log_audit "policy_remove" "" "pattern=$pattern"
            ;;

        list)
            echo "=== Trust Policies ==="
            echo ""
            local policies=$(sqlite3 "$DB_PATH" "SELECT pattern, trust_level, datetime(created_at, 'unixepoch') FROM policies ORDER BY created_at")

            if [ -z "$policies" ]; then
                echo "No policies defined."
                echo ""
                echo "Add policies with: /trust-policy add <pattern> <trust-level>"
            else
                echo "Pattern                          Trust       Created"
                echo "-------------------------------  ----------  -------------------"
                sqlite3 "$DB_PATH" "SELECT printf('%-32s %-10s %s', pattern, trust_level, datetime(created_at, 'unixepoch')) FROM policies ORDER BY created_at"
            fi
            ;;

        *)
            echo "Usage: /trust-policy <add|remove|list> [pattern] [trust-level]"
            echo ""
            echo "Examples:"
            echo "  /trust-policy add \"internal:*\" trusted"
            echo "  /trust-policy add \"moltbook:*\" untrusted"
            echo "  /trust-policy list"
            echo "  /trust-policy remove \"moltbook:*\""
            return 1
            ;;
    esac
}

# Quarantine content
cmd_quarantine() {
    local id="$1"
    shift
    local reason="$*"

    if [ -z "$id" ]; then
        echo "Usage: /quarantine <id> [reason]"
        return 1
    fi

    local esc_id=$(sql_escape "$id")

    # Check if content exists
    local exists=$(sqlite3 "$DB_PATH" "SELECT id FROM content WHERE id = '$esc_id' LIMIT 1")

    if [ -z "$exists" ]; then
        echo "Error: No provenance record for '$id'"
        echo "Mark the content first with /mark-source"
        return 1
    fi

    # Check if already quarantined
    local already=$(sqlite3 "$DB_PATH" "SELECT id FROM quarantine WHERE content_id = '$esc_id' LIMIT 1")

    if [ -n "$already" ]; then
        echo "Content '$id' is already quarantined"
        return 1
    fi

    local now=$(date +%s)
    local reason_text="${reason:-No reason provided}"
    local esc_reason=$(sql_escape "$reason_text")

    sqlite3 "$DB_PATH" "INSERT INTO quarantine (content_id, reason, quarantined_at) VALUES ('$esc_id', '$esc_reason', $now)"
    sqlite3 "$DB_PATH" "UPDATE content SET trust_level = 'untrusted' WHERE id = '$esc_id'"

    echo "Quarantined '$id': $reason_text"

    log_audit "quarantine" "$id" "reason=$reason_text"
}

# List quarantined content
cmd_quarantine_list() {
    echo "=== Quarantined Content ==="
    echo ""

    local count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM quarantine")

    if [ "$count" -eq 0 ]; then
        echo "No content is currently quarantined."
        return
    fi

    sqlite3 "$DB_PATH" "
        SELECT 'ID: ' || q.content_id || char(10) ||
               '  Source: ' || c.source || char(10) ||
               '  Reason: ' || q.reason || char(10) ||
               '  Quarantined: ' || datetime(q.quarantined_at, 'unixepoch') || char(10)
        FROM quarantine q
        JOIN content c ON q.content_id = c.id
        ORDER BY q.quarantined_at DESC
    "

    echo "Total: $count items"
}

# Verify trust against policies
cmd_verify_trust() {
    local id="$1"

    if [ -z "$id" ]; then
        echo "Usage: /verify-trust <id>"
        return 1
    fi

    local esc_id=$(sql_escape "$id")
    local result=$(sqlite3 -separator '|' "$DB_PATH" "SELECT source, trust_level FROM content WHERE id = '$esc_id'")

    if [ -z "$result" ]; then
        echo "UNKNOWN: No provenance record for '$id'"
        return 1
    fi

    IFS='|' read -r source trust_level <<< "$result"

    # Check quarantine first
    local qcount=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM quarantine WHERE content_id = '$esc_id'")
    if [ "$qcount" -gt 0 ]; then
        echo "FAIL: Content is quarantined"
        return 1
    fi

    # Check current trust level
    case "$trust_level" in
        trusted)
            echo "PASS: Content is trusted (source: $source)"
            return 0
            ;;
        untrusted)
            echo "FAIL: Content is untrusted (source: $source)"
            return 1
            ;;
        unknown)
            echo "UNKNOWN: Content trust is unknown (source: $source)"
            echo "Consider adding a trust policy for this source pattern"
            return 1
            ;;
    esac
}

# Stats command for overview
cmd_stats() {
    echo "=== Provenance Statistics ==="
    echo ""

    local total=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM content")
    local trusted=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM content WHERE trust_level = 'trusted'")
    local untrusted=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM content WHERE trust_level = 'untrusted'")
    local unknown=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM content WHERE trust_level = 'unknown'")
    local quarantined=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM quarantine")
    local policies=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM policies")

    echo "Content tracked: $total"
    echo "  Trusted:   $trusted"
    echo "  Untrusted: $untrusted"
    echo "  Unknown:   $unknown"
    echo ""
    echo "Quarantined: $quarantined"
    echo "Policies:    $policies"
    echo ""
    echo "Recent activity:"
    sqlite3 "$DB_PATH" "
        SELECT '  ' || action || ' on ' || COALESCE(content_id, '-') || ' at ' || datetime(timestamp, 'unixepoch')
        FROM audit_log
        ORDER BY timestamp DESC
        LIMIT 5
    "
}

# Main dispatch
main() {
    init_db

    local cmd="$1"
    shift 2>/dev/null || true

    case "$cmd" in
        mark-source|mark)
            cmd_mark_source "$@"
            ;;
        check-provenance|check|prov)
            cmd_check_provenance "$@"
            ;;
        trust-policy|policy)
            cmd_trust_policy "$@"
            ;;
        quarantine)
            cmd_quarantine "$@"
            ;;
        quarantine-list|qlist)
            cmd_quarantine_list
            ;;
        verify-trust|verify)
            cmd_verify_trust "$@"
            ;;
        stats)
            cmd_stats
            ;;
        help|--help|-h)
            echo "Provenance - Content origin tracking for AI agents"
            echo ""
            echo "Commands:"
            echo "  mark-source <id> <source> [trust]  - Mark content provenance"
            echo "  check-provenance <id>              - View provenance record"
            echo "  trust-policy add|remove|list       - Manage trust policies"
            echo "  quarantine <id> [reason]           - Quarantine content"
            echo "  quarantine-list                    - List quarantined content"
            echo "  verify-trust <id>                  - Check if content passes trust"
            echo "  stats                              - Show statistics"
            echo ""
            echo "Trust levels: trusted, untrusted, unknown"
            ;;
        *)
            echo "Unknown command: $cmd"
            echo "Run with 'help' for usage information."
            return 1
            ;;
    esac
}

main "$@"
