#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034,SC2016  # stubs are invoked by the script under test; SCRIPT is read by the .bats files
# tests/tool-freshness-env.bash — sandbox shared by tool-freshness.bats and
# tool-update.bats: a fake $HOME with the user-level layout tool-freshness.sh
# and lib/tool-update.sh expect (~/.bun/bin/bun, ~/.local/bin/{gh,shellcheck,
# pg_dump,pg_restore}, ~/.local/opt/postgresql-17), every network lookup and
# download answered from fixtures, ntfy appended to $NTFY_OUT, and every
# stubbed side effect (bun upgrade, systemctl, pg_ctl, make) appended to $CALLS.
#
# Installed versions come from STUB_* and latest ones from LATEST_*; override
# them in a test before calling install_fake_tools again (setup installs once).

tool_freshness_sandbox() {
    export SANDBOX="$BATS_TMPDIR/tool-freshness-$$"
    rm -rf "$SANDBOX"
    mkdir -p "$SANDBOX/home" "$SANDBOX/state" "$SANDBOX/archon/.git" "$SANDBOX/scratch" "$SANDBOX/fixtures/dl"
    export HOME="$SANDBOX/home"
    export ARCHON_CRON_SECRETS="$SANDBOX/secrets.env"
    echo 'NTFY_TOPIC=test-topic' > "$ARCHON_CRON_SECRETS"
    export TOOL_FRESHNESS_STATE_DIR="$SANDBOX/state"
    export TOOL_FRESHNESS_ARCHON_DIR="$SANDBOX/archon"
    export TOOL_FRESHNESS_NODE_INDEX_URL="file://node-index"
    export TOOL_FRESHNESS_NODE_SCHEDULE_URL="file://node-schedule"
    export TOOL_FRESHNESS_TODAY="2026-09-21"
    export TOOL_UPDATE_SCRATCH_ROOT="$SANDBOX/scratch"
    export TOOL_UPDATE_RELEASES="https://releases.test"
    export TOOL_UPDATE_PGVECTOR_REPO="https://releases.test/pgvector.git"
    export TOOL_UPDATE_HEALTH_URL="http://health.test/"
    export TOOL_UPDATE_HEALTH_INTERVAL=0 TOOL_UPDATE_HEALTH_TRIES=3
    export ARCHON_RUNS_SNAPSHOT="$SANDBOX/runs-snapshot"
    export NTFY_OUT="$SANDBOX/ntfy"          # every curl to ntfy.sh appends its argv here
    export CALLS="$SANDBOX/calls"            # stubbed side effects, one line each
    export FIXTURES="$SANDBOX/fixtures"

    # Installed versions.
    export STUB_BUN=1.4.2 STUB_GH=2.101.0 STUB_SHELLCHECK=0.11.0 STUB_UV=0.12.17 STUB_NODE=v24.21.0 STUB_PG=17.11
    export STUB_ARCHON_DESCRIBE=v0.10.1-14-gac9c9f21
    export STUB_ARCHON_TAG_IN_HEAD=1         # merge-base --is-ancestor result
    export STUB_ARCHON_BEHIND=37
    # Latest versions.
    export LATEST_BUN=bun-v1.4.2 LATEST_GH=v2.101.0 LATEST_SHELLCHECK=v0.11.0 LATEST_UV=0.12.17 LATEST_ARCHON=v0.10.1
    export LATEST_PG_TAGS=$'18.1.0\n17.11.0\n17.10.0\n16.9.0'
    # Apply-side knobs.
    export STUB_HEALTH=200                   # what the archon-serve health URL answers
    export STUB_RUNS='{"runs": []}'          # `archon workflow runs --status running` payload
    export STUB_RUNS_RC=0
    export STUB_PGREP_RC=1                   # 1: no `archon workflow run` process
    export STUB_GH_AUTH_RC=0                 # `gh auth status` after an install
    export STUB_SYSTEMCTL_RC=0
    export STUB_MAKE_RC=0
    write_node_fixtures v24.21.0 Krypton
    install_fake_tools

    uv()   { echo "uv $STUB_UV (abc 2026-01-01 x86_64-unknown-linux-gnu)"; }
    node() { echo "$STUB_NODE"; }
    gh() {
        case "$1" in
            --version) "$HOME/.local/bin/gh" --version; return ;;
            auth)      return "$STUB_GH_AUTH_RC" ;;
        esac
        case "$2" in
            repos/oven-sh/bun/releases/latest)          echo "$LATEST_BUN" ;;
            repos/cli/cli/releases/latest)              echo "$LATEST_GH" ;;
            repos/koalaman/shellcheck/releases/latest)  echo "$LATEST_SHELLCHECK" ;;
            repos/koalaman/shellcheck/releases/tags/*)  cat "$FIXTURES/shellcheck.digest" 2>/dev/null ;;
            repos/coleam00/archon/releases/latest)      echo "$LATEST_ARCHON" ;;
            repos/theseus-rs/postgresql-binaries/releases*) printf '%s\n' "$LATEST_PG_TAGS" ;;
            *) echo "gh stub: unexpected $*" >&2; return 1 ;;
        esac
    }
    # curl: nodejs fixtures, release downloads (-o dest url → copy from
    # $FIXTURES/dl, 22 when missing like --fail), the health URL, ntfy.
    curl() {
        local a dest="" url="" want_dest=0
        for a in "$@"; do
            if [ "$want_dest" = 1 ]; then dest="$a"; want_dest=0; continue; fi
            case "$a" in
                -o)                   want_dest=1 ;;
                file://node-index)    cat "$FIXTURES/index.json"; return 0 ;;
                file://node-schedule) cat "$FIXTURES/schedule.json"; return 0 ;;
                ntfy.sh/*)            printf '%s\n' "$@" >> "$NTFY_OUT"; return 0 ;;
                http://health.test/*) printf '%s' "$STUB_HEALTH"; return 0 ;;
                https://releases.test/*) url="$a" ;;
            esac
        done
        if [ -n "$url" ]; then
            echo "curl $url" >> "$CALLS"
            [ -f "$FIXTURES/dl/$(basename "$url")" ] || return 22
            cp "$FIXTURES/dl/$(basename "$url")" "$dest"; return 0
        fi
        echo "curl stub: unexpected $*" >&2; return 1
    }
    git() {
        [ "$1" = "-C" ] && shift 2
        case "$1 ${2:-}" in
            "remote ")            printf 'origin\nupstream\n' ;;
            "remote get-url")     echo "https://github.com/coleam00/archon" ;;
            "describe --tags")    echo "$STUB_ARCHON_DESCRIBE" ;;
            "fetch -q")           : ;;
            "ls-remote --symref") printf 'ref: refs/heads/dev\tHEAD\nabc123\tHEAD\n' ;;
            "ls-remote upstream") printf 'deadbeef\trefs/tags/%s^{}\n' "$LATEST_ARCHON" ;;
            "rev-list --count")   echo "$STUB_ARCHON_BEHIND" ;;
            "merge-base --is-ancestor") [ "$STUB_ARCHON_TAG_IN_HEAD" = 1 ] ;;
            "clone -q")           echo "git $*" >> "$CALLS"; mkdir -p "${*: -1}" ;;
            *) echo "git stub: unexpected $*" >&2; return 1 ;;
        esac
    }
    # make: the pgvector build. `install` drops vector.so + vector.control
    # where the given PG_CONFIG says — the new tree when it is relocatable.
    make() {
        local a cfg="" install=0
        for a in "$@"; do
            case "$a" in PG_CONFIG=*) cfg="${a#PG_CONFIG=}" ;; install) install=1 ;; esac
        done
        echo "make $*" >> "$CALLS"
        [ "$STUB_MAKE_RC" = 0 ] || { echo "make: *** [vector.o] Error 1"; return "$STUB_MAKE_RC"; }
        if [ "$install" = 1 ]; then
            local lib share
            lib=$("$cfg" --pkglibdir) && share=$("$cfg" --sharedir) || return 1
            mkdir -p "$lib" "$share/extension"
            : > "$lib/vector.so"
            printf "default_version = '0.8.1'\n" > "$share/extension/vector.control"
        fi
    }
    archon() {
        echo "archon $*" >> "$CALLS"
        if [[ " $* " == *" --status running "* ]]; then printf '%s' "$STUB_RUNS"; else printf '{"runs": []}'; fi
        return "$STUB_RUNS_RC"
    }
    # snap info astral-uv: the tracked channel and what it offers ($LATEST_UV;
    # empty = the store answered nothing usable, like an offline box).
    snap() {
        [ "$1 $2" = "info astral-uv" ] || { echo "snap stub: unexpected $*" >&2; return 1; }
        [ -n "$LATEST_UV" ] || return 1
        printf 'name:      astral-uv\ntracking:     latest/stable\nchannels:\n  latest/stable:    %s 2026-08-27 (1682) 21.4MB classic\n  latest/candidate: --\n  latest/edge:      0.13.0 2026-09-10 (1700) 21.4MB classic\ninstalled:          %s (1682) 21.4MB classic\n' "$LATEST_UV" "$STUB_UV"
    }
    pgrep()     { return "$STUB_PGREP_RC"; }
    systemctl() { echo "systemctl $*" >> "$CALLS"; return "$STUB_SYSTEMCTL_RC"; }
    export -f uv node gh curl git make archon snap pgrep systemctl

    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tool-freshness.sh"
}

tool_freshness_teardown() {
    rm -rf "$SANDBOX"
}

# write_node_fixtures <newest-lts-version> <codename>: index.json newest-first
# with a Current line above the LTS one; schedule.json with v20 already EOL.
write_node_fixtures() {
    cat > "$FIXTURES/index.json" <<JSON
[
  {"version": "v26.9.0", "lts": false},
  {"version": "$1", "lts": "$2"},
  {"version": "v24.20.0", "lts": "$2"},
  {"version": "v22.22.0", "lts": "Jod"},
  {"version": "v20.20.2", "lts": "Iron"}
]
JSON
    cat > "$FIXTURES/schedule.json" <<'JSON'
{
  "v20": {"start": "2023-04-18", "lts": "2023-10-24", "end": "2026-04-30"},
  "v22": {"start": "2024-04-24", "lts": "2024-10-29", "end": "2027-04-30"},
  "v24": {"start": "2025-05-06", "lts": "2025-10-28", "end": "2028-04-30"},
  "v26": {"start": "2026-04-22", "end": "2029-04-30"}
}
JSON
}

# ---------------------------------------------------------------------------
# Fake installed tools — real files, so an install replaces them.
# ---------------------------------------------------------------------------

# make_gh_bin <version> <dest> — `gh auth status` answers STUB_GH_AUTH_RC.
make_gh_bin() {
    printf '#!/usr/bin/env bash\ncase "$1" in auth) exit "${STUB_GH_AUTH_RC:-0}" ;; esac\necho "gh version %s (2026-01-01)"\n' "$1" > "$2"; chmod +x "$2"
}

# make_shellcheck_bin <version> <dest>
make_shellcheck_bin() {
    printf '#!/usr/bin/env bash\nprintf "ShellCheck - shell script analysis tool\\nversion: %s\\n"\n' "$1" > "$2"; chmod +x "$2"
}

# make_pg_tree <dir> <version major.minor> [ok|broken|badversion] — the bin/
# stubs of a portable PostgreSQL tree. pg_config answers relative to its own
# location (the real build is relocatable); psql's CREATE EXTENSION only
# succeeds when vector.control exists in the same tree. `broken`: psql fails.
# `badversion`: pg_dump reports one minor lower than the tree claims.
make_pg_tree() {
    local dir="$1" v="$2" mode="${3:-ok}" reported="$2"
    [ "$mode" = badversion ] && reported="${v%.*}.$(( ${v#*.} - 1 ))"
    mkdir -p "$dir/bin" "$dir/lib" "$dir/share"
    printf '#!/usr/bin/env bash\necho "pg_dump (PostgreSQL) %s"\n' "$reported" > "$dir/bin/pg_dump"
    printf '#!/usr/bin/env bash\necho "pg_restore (PostgreSQL) %s"\n' "$v" > "$dir/bin/pg_restore"
    printf '#!/usr/bin/env bash\necho "postgres (PostgreSQL) %s"\n' "$v" > "$dir/bin/postgres"
    cat > "$dir/bin/pg_config" <<'STUB'
#!/usr/bin/env bash
here=$(cd "$(dirname "$0")/.." && pwd)
for a in "$@"; do case "$a" in
  --pkglibdir) echo "$here/lib" ;; --sharedir) echo "$here/share" ;; --bindir) echo "$here/bin" ;;
esac; done
STUB
    cat > "$dir/bin/initdb" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" = -D ] && { mkdir -p "$2/base"; echo "initdb $2" >> "$CALLS"; }; shift; done
STUB
    cat > "$dir/bin/pg_ctl" <<'STUB'
#!/usr/bin/env bash
echo "pg_ctl ${*: -1} $(cd "$(dirname "$0")/.." && pwd)" >> "$CALLS"
STUB
    if [ "$mode" = broken ]; then
        printf '#!/usr/bin/env bash\necho "psql: error: connection refused" >&2\nexit 2\n' > "$dir/bin/psql"
    else
        cat > "$dir/bin/psql" <<'STUB'
#!/usr/bin/env bash
here=$(cd "$(dirname "$0")/.." && pwd)
echo "psql $*" >> "$CALLS"
[ -f "$here/share/extension/vector.control" ] || { echo 'ERROR:  extension "vector" is not available' >&2; exit 1; }
STUB
    fi
    chmod +x "$dir"/bin/*
}

# install_fake_tools — (re)create the fake $HOME layout from STUB_*.
install_fake_tools() {
    mkdir -p "$HOME/.bun/bin" "$HOME/.local/bin" "$HOME/.local/opt"
    cat > "$HOME/.bun/bin/bun" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --version) cat "$HOME/.bun/version" ;;
  upgrade)   echo "bun $*" >> "$CALLS"; v="${LATEST_BUN#bun-v}"; echo "$v" > "$HOME/.bun/version"; echo "Upgraded to $v" ;;
esac
STUB
    chmod +x "$HOME/.bun/bin/bun"
    echo "$STUB_BUN" > "$HOME/.bun/version"
    make_gh_bin "$STUB_GH" "$HOME/.local/bin/gh"
    make_shellcheck_bin "$STUB_SHELLCHECK" "$HOME/.local/bin/shellcheck"
    rm -rf "$HOME/.local/opt/postgresql-17"
    make_pg_tree "$HOME/.local/opt/postgresql-17" "$STUB_PG"
    : > "$HOME/.local/opt/postgresql-17/lib/vector.so"
    mkdir -p "$HOME/.local/opt/postgresql-17/share/extension"
    printf "default_version = '0.8.1'\n" > "$HOME/.local/opt/postgresql-17/share/extension/vector.control"
    ln -sfn ../opt/postgresql-17/bin/pg_dump    "$HOME/.local/bin/pg_dump"
    ln -sfn ../opt/postgresql-17/bin/pg_restore "$HOME/.local/bin/pg_restore"
}

# ---------------------------------------------------------------------------
# Release fixtures under $FIXTURES/dl, named like the real assets.
# ---------------------------------------------------------------------------

# make_gh_release <version> [checksum-hex-override]: gh_<v>_linux_amd64.tar.gz
# + gh_<v>_checksums.txt (with unrelated assets listed too, like the real one).
make_gh_release() {
    local v="$1" d asset hex
    d="$FIXTURES/build/gh_${v}_linux_amd64"; asset="gh_${v}_linux_amd64.tar.gz"
    rm -rf "$d"; mkdir -p "$d/bin"
    make_gh_bin "$v" "$d/bin/gh"
    tar czf "$FIXTURES/dl/$asset" -C "$FIXTURES/build" "gh_${v}_linux_amd64"
    hex="${2:-$(sha256sum "$FIXTURES/dl/$asset" | cut -d' ' -f1)}"
    {
        echo "0000000000000000000000000000000000000000000000000000000000000000  gh_${v}_linux_386.tar.gz"
        echo "$hex  $asset"
        echo "1111111111111111111111111111111111111111111111111111111111111111  gh_${v}_linux_arm64.tar.gz"
    } > "$FIXTURES/dl/gh_${v}_checksums.txt"
}

# make_shellcheck_release <tag> [digest-hex-override]: shellcheck-<tag>.linux.x86_64.tar.xz
# and the sha256 digest the release API reports for it.
make_shellcheck_release() {
    local tag="$1" d asset hex
    d="$FIXTURES/build/shellcheck-$tag"; asset="shellcheck-$tag.linux.x86_64.tar.xz"
    rm -rf "$d"; mkdir -p "$d"
    make_shellcheck_bin "${tag#v}" "$d/shellcheck"
    tar cJf "$FIXTURES/dl/$asset" -C "$FIXTURES/build" "shellcheck-$tag"
    hex="${2:-$(sha256sum "$FIXTURES/dl/$asset" | cut -d' ' -f1)}"
    echo "sha256:$hex" > "$FIXTURES/shellcheck.digest"
}

# make_pg_release <tag> [ok|broken|badversion] [sha256-hex-override]:
# postgresql-<tag>-x86_64-unknown-linux-gnu.tar.gz + .sha256, no pgvector inside.
make_pg_release() {
    local tag="$1" mode="${2:-ok}" name="postgresql-$1-x86_64-unknown-linux-gnu" hex
    rm -rf "$FIXTURES/build/$name"
    make_pg_tree "$FIXTURES/build/$name" "${tag%.*}" "$mode"
    tar czf "$FIXTURES/dl/$name.tar.gz" -C "$FIXTURES/build" "$name"
    hex="${3:-$(sha256sum "$FIXTURES/dl/$name.tar.gz" | cut -d' ' -f1)}"
    echo "$hex  $name.tar.gz" > "$FIXTURES/dl/$name.tar.gz.sha256"
}
