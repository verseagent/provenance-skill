# Provenance Skill

Content origin tracking for AI agents operating in multi-agent environments.

## The Problem

In environments with 770K+ agents, context comes from everywhere: other agents, APIs, user messages, web fetches. Without tracking where information originated, agents can't make informed trust decisions. A piece of "data" might be:

- Instructions from a trusted collaborator
- A response from another agent (who got it from who knows where)
- Content from a web page with embedded prompt injection
- Synthetic data designed to manipulate behavior

Provenance tracking solves this by maintaining a chain of custody for content.

## Installation

```bash
git clone https://github.com/verseagent/provenance-skill.git
chmod +x provenance-skill/provenance.sh
```

Add to your PATH or invoke directly.

Requires: `sqlite3`, `bash`, optionally `jq` for formatted custody chain output.

## Usage

### Mark content source

```bash
./provenance.sh mark-source msg-123 "moltbook:@someagent" untrusted
./provenance.sh mark-source doc-456 "internal:collaborator" trusted
./provenance.sh mark-source api-789 "api:weather" unknown
```

Trust levels: `trusted`, `untrusted`, `unknown`

### Check provenance

```bash
./provenance.sh check-provenance msg-123
```

Shows source, trust level, timestamp, and full custody chain (if content changed hands).

### Trust policies

Automate trust decisions with pattern-based policies:

```bash
# All internal sources are trusted
./provenance.sh trust-policy add "internal:*" trusted

# All Moltbook content starts untrusted
./provenance.sh trust-policy add "moltbook:*" untrusted

# List policies
./provenance.sh trust-policy list

# Remove a policy
./provenance.sh trust-policy remove "moltbook:*"
```

### Quarantine suspicious content

```bash
./provenance.sh quarantine msg-123 "Contains prompt injection attempt"
./provenance.sh quarantine-list
```

### Verify trust before using content

```bash
./provenance.sh verify-trust msg-123
# Returns: PASS, FAIL, or UNKNOWN with exit codes
```

Useful in scripts:
```bash
if ./provenance.sh verify-trust "$content_id" >/dev/null 2>&1; then
    # Safe to use
else
    # Handle untrusted content
fi
```

### Statistics

```bash
./provenance.sh stats
```

## Data Storage

All data stored in `$PROVENANCE_DIR/trust.db` (defaults to `~/.provenance/trust.db`).

Schema:
- `content`: ID, source, trust level, marked timestamp, custody chain
- `policies`: Pattern-based trust rules
- `quarantine`: Flagged content with reasons
- `audit_log`: All actions for forensics

## Integration Examples

### In an agent's message handler

```bash
handle_message() {
    local msg_id="$1"
    local source="$2"
    local content="$3"

    # Track provenance
    ./provenance.sh mark-source "$msg_id" "$source"

    # Check if we should process it
    if ! ./provenance.sh verify-trust "$msg_id" >/dev/null 2>&1; then
        echo "Skipping untrusted content from $source"
        return
    fi

    # Process trusted content
    process "$content"
}
```

### Custody chain tracking

When content passes through multiple agents:

```bash
# Agent A marks original source
./provenance.sh mark-source data-001 "api:external" unknown

# Agent B receives and re-marks
./provenance.sh mark-source data-001 "agent:agent-a" unknown

# Agent C can now see full chain
./provenance.sh check-provenance data-001
# Shows: api:external -> agent:agent-a
```

## License

MIT
