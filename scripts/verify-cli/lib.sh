# The frame every verify-cli scenario sources: refusals, bounded commands, the PASS/FAIL tally, the cost
# summary and the cleanup. A scenario (scripts/verify-cli/<feature>.sh) is then only its goal, the state it
# sets up and its checks:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#   preflight                      refuses (exit 2, nothing changed) or builds .build/debug/workbench
#   start_thread <name> <goal.md>  goal new, the cap, goal approve; sets ID, BRANCH, THREAD_DIR
#   run_thread                     workbench run, then checks the turn used the real claude; sets WT
#   check "<step>" "<why>" <command...>
#   remove_on_pass worktree <path> | branch <name>
#   finish                         summary, cleanup on pass, RESULT line, exit 0 or 1
# Environment: VERIFY_CLI_BUDGET_USD (default 0.50), VERIFY_CLI_MODEL (default haiku), VERIFY_CLI_BUILD (debug, the
# default, or release: which binary is built and checked), VERIFY_CLI_FROM_BRANCH=1
# (run from a branch that contains origin's main), VERIFY_CLI_SABOTAGE=cleanup (a cleanup step fails on purpose;
# a scenario's own VERIFY_CLI_SABOTAGE=1 breaks its feature). See .agents/skills/verify-cli/SKILL.md.
set -u

BUDGET_USD=${VERIFY_CLI_BUDGET_USD:-0.50}
MODEL=${VERIFY_CLI_MODEL:-haiku}
SABOTAGE=${VERIFY_CLI_SABOTAGE:-0}
SCENARIO=$(basename "$0" .sh)
TURN_TIMEOUT_MIN=10
# Seconds per command; `run` holds the turn plus the project's check.
T_BUILD=900
T_GIT=60
T_WB=120
T_RUN=$(( (TURN_TIMEOUT_MIN + 10) * 60 ))

SCRATCH=""
ROOT=""
WB=""
BASE_SHA=""
ID=""
BRANCH=""
THREAD_DIR=""
WT=""
die() { echo "refused: $*" >&2; [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"; exit 2; }

# The watchdog reports a timeout on fd 3 (the script's stderr) and keeps its own stdout and stderr quiet:
# `$(with_timeout ...)` then does not wait for it, and ending its sleep prints no "Terminated" line.
exec 3>&2
CHILD=""
# Runs "$@" for at most $1 seconds: SIGTERM first (a `workbench run` then stops its turn and records it),
# SIGKILL 10 s later.
with_timeout() {
    local secs=$1; shift
    "$@" &
    local pid=$!
    CHILD=$pid
    ( sleep "$secs" && { kill -TERM "$pid" 2>/dev/null || exit 0
        echo "timed out after ${secs}s: $*" >&3; sleep 10 && kill -KILL "$pid" 2>/dev/null; } ) >/dev/null 2>&1 &
    local dog=$!
    wait "$pid"
    local rc=$?
    CHILD=""
    # Ending the watchdog's sleep ends the watchdog: each step after a sleep needs the sleep to have finished.
    pkill -P "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
    return $rc
}

# A workbench command, printed before it runs and kept for the summary (in a file: `$(wb ...)` is a subshell).
wb() {
    local secs=$1; shift
    echo "\$ workbench $*" >&2
    [ -n "$SCRATCH" ] && echo "workbench $*" >>"$SCRATCH/commands"
    with_timeout "$secs" "$WB" "$@"
}

g() { with_timeout "$T_GIT" git "$@"; }

# Reads JSON on stdin with Python code over `d` (one document, else None) and `lines` (JSON lines).
py() { python3 -I -c "import json,sys
def _p(s):
    try: return json.loads(s)
    except ValueError: return None
raw=sys.stdin.read()
d=_p(raw)
lines=[x for x in map(_p, raw.splitlines()) if isinstance(x, dict)]
$1"; }

PASSED=()
FAILED=()
pass() { PASSED+=("$1"); printf 'PASS  %s\n' "$1"; }
fail() { FAILED+=("$1"); printf 'FAIL  %s: %s\n' "$1" "$2"; }
check() { local name=$1 why=$2; shift 2; if "$@"; then pass "$name"; else fail "$name" "$why"; return 1; fi; }

branch_exists() { g rev-parse -q --verify "refs/heads/$1" >/dev/null; }

# --- refuse before anything changes -------------------------------------------------------------------

preflight() {
    command -v python3 >/dev/null || die "python3 is needed to read workbench's JSON"
    ROOT=$(g rev-parse --show-toplevel 2>/dev/null) || die "not in a git repository"
    cd "$ROOT" || die "cannot enter $ROOT"
    [ "$(g rev-parse --absolute-git-dir)" = "$(cd "$(g rev-parse --git-common-dir)" && pwd -P)" ] \
        || die "run it in the main checkout of this repository, not in a linked worktree"
    [ -f Package.swift ] && [ -f scripts/verify-cli/lib.sh ] || die "$ROOT is not the Workbench repository"
    [[ $BUDGET_USD =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "VERIFY_CLI_BUDGET_USD must be a number of dollars, got '$BUDGET_USD'"
    [[ $MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "VERIFY_CLI_MODEL is not a model name: '$MODEL'"

    # VERIFY_CLI_CI=1 (a free scenario in CI): the checkout is a pull request's merge commit with no project config and no real
    # `claude`, so the checks about origin's main, an active thread and the real claude are skipped. Nothing else is.
    CI_MODE=${VERIFY_CLI_CI:-0}
    local porcelain
    porcelain=$(g status --porcelain) || die "git status failed"
    [ -z "$porcelain" ] || die "the checkout has local changes (git status); commit or set them aside"
    BASE_SHA=""
    if [ "$CI_MODE" = 1 ]; then
        echo "==> CI mode: not checked against origin's main"
    else
        BASE_SHA=$(g ls-remote origin refs/heads/main | cut -f1)
        [ -n "$BASE_SHA" ] || die "could not read main from origin"
        if [ "${VERIFY_CLI_FROM_BRANCH:-0}" = 1 ]; then
            # Before the merge: the branch under test, which must contain origin's main so the feature being checked is in.
            g merge-base --is-ancestor "$BASE_SHA" HEAD \
                || die "VERIFY_CLI_FROM_BRANCH=1: HEAD ($(g rev-parse --short HEAD)) does not contain origin's main ($BASE_SHA)"
            echo "==> from branch $(g rev-parse --abbrev-ref HEAD) at $(g rev-parse --short HEAD) (VERIFY_CLI_FROM_BRANCH=1)"
        else
            [ "$(g rev-parse HEAD)" = "$BASE_SHA" ] \
                || die "HEAD is not origin's main ($BASE_SHA); check it out, or VERIFY_CLI_FROM_BRANCH=1 to run from a branch that contains it"
        fi
        [ "$(g rev-parse -q --verify origin/main)" = "$BASE_SHA" ] \
            || die "origin/main is behind origin; run git fetch origin main"
    fi

    SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/verify-cli-$SCENARIO.XXXXXX") || die "mktemp failed"
    # `release` builds and checks the optimized binary a user would install: it can behave differently from the debug one that
    # the unit tests run, and no unit test can tell (they cannot run in release).
    BUILD=${VERIFY_CLI_BUILD:-debug}
    case "$BUILD" in
        debug) BUILD_FLAGS=() ;;
        release) BUILD_FLAGS=(-c release) ;;
        *) die "VERIFY_CLI_BUILD must be debug or release, got '$BUILD'" ;;
    esac
    echo "==> building workbench ($BUILD)"
    with_timeout "$T_BUILD" swift build ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --product workbench || die "swift build failed"
    WB="$ROOT/.build/$BUILD/workbench"
    [ -x "$WB" ] || die "no $WB after the build"

    if [ "$CI_MODE" = 1 ]; then trap interrupted INT TERM; return 0; fi
    local active claude
    active=$(wb "$T_WB" status --all --json | py "print(' '.join(t['thread'] for t in d['threads'] if t['ended'] is None))") \
        || die "workbench status --all --json failed"
    [ -z "$active" ] || die "thread $active is active here (one project, one active thread); end it first"

    claude=$(wb "$T_WB" config | sed -n 's/^claude: *//p')
    case "$claude" in
        ""|NOT\ FOUND*) die "claude_path does not resolve: '${claude}'" ;;
        *fake-claude*) die "claude_path resolves to the test double ($claude); this scenario needs the real claude" ;;
    esac
    echo "==> claude: $claude"
    trap interrupted INT TERM
}

interrupted() {
    # A background child does not get the terminal's Ctrl-C; a run asked with SIGTERM records its turn as stopped.
    [ -n "$CHILD" ] && kill -TERM "$CHILD" 2>/dev/null && wait "$CHILD"
    echo
    echo "interrupted; left as they are: thread ${ID:-none}, branch ${BRANCH:-none}, $SCRATCH"
    [ -n "$ID" ] && echo "if the thread is still active: $WB abandon --force"
    exit 130
}

# --- the thread ---------------------------------------------------------------------------------------

# goal new from $2 under the name $1, capped at $BUDGET_USD and $TURN_TIMEOUT_MIN on $MODEL, then approved.
start_thread() {
    local name=$1 src=$2 created goal approval budget timeout
    created=$(wb "$T_WB" goal new "$name" --base origin/main --from "$src") || { echo "$created"; die "goal new failed"; }
    echo "$created"
    ID=$(echo "$created" | sed -n 's/^created //p')
    [[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "goal new printed no thread id"
    BRANCH="workbench/$ID"
    THREAD_DIR="$ROOT/.workbench/threads/$ID"
    # The draft takes the config's budget and a 30 minute timeout; this run is capped lower and uses $MODEL.
    perl -pi -e "s/^budget_usd: .*/budget_usd: $BUDGET_USD/; s/^turn_timeout_min: .*/turn_timeout_min: $TURN_TIMEOUT_MIN/; s/^# model: .*/model: $MODEL/" \
        "$THREAD_DIR/goal.md"

    wb "$T_WB" goal approve "$ID"
    goal=$(wb "$T_WB" status "$ID" --json | py "g=d['goal']; print(g['approval'], g['budget_usd'], g['turn_timeout_min'])")
    read -r approval budget timeout <<<"$goal"
    # Never spend more than asked: a goal that did not take the cap is ended before any turn.
    if ! python3 -I -c "import sys; sys.exit(abs(float(sys.argv[1]) - float(sys.argv[2])) > 1e-9)" "${budget:-x}" "$BUDGET_USD" 2>/dev/null \
        || [ "${timeout:-}" != "$TURN_TIMEOUT_MIN" ]; then
        wb "$T_WB" abandon "$ID"
        die "the goal has budget '${budget:-?}' and timeout '${timeout:-?}', not $BUDGET_USD and $TURN_TIMEOUT_MIN; thread $ID abandoned unrun"
    fi
    check "goal approved with a $BUDGET_USD USD cap" "approval is '${approval:-?}'" test "${approval:-}" = approved
}

# One real turn: `workbench run`, then the log and transcript must show the real claude (turn.started argv, system/init line).
run_thread() {
    local run_exit log argv0 stream
    wb "$T_RUN" run "$ID"
    run_exit=$?
    check "run: the turn succeeded" "workbench run exited $run_exit" test "$run_exit" = 0

    log=$(wb "$T_WB" log "$ID" --json)
    argv0=$(echo "$log" | py "s=[e for e in lines if e['kind']=='turn.started']; print(s[-1]['data']['argv'][0] if s else '')")
    # The stream lines are the turn's transcript, not events of the log.
    stream=$(wb "$T_WB" log "$ID" --transcript | py "c=lines
init=[x for x in c if isinstance(x,dict) and x.get('type')=='system' and x.get('subtype')=='init']
print(len(c), init[0].get('model','?') if init else '-', init[0].get('claude_code_version','?') if init else '-')")
    echo "    turn argv[0]: $argv0; claude lines, model, version: $stream"
    check "run: real claude stream lines in the transcript" "argv[0] '$argv0', stream '$stream'" \
        bash -c '[ -n "$1" ] && [[ $1 != *fake-claude* ]] && [ "${2%% *}" -gt 0 ] && [[ $2 != *" - -" ]]' _ "$argv0" "$stream"

    WT=$(wb "$T_WB" status "$ID" --json | py "print(d['worktree']['path'] or '')")
}

# --- cleanup and summary ------------------------------------------------------------------------------

CLEANUP=()
# What the scenario made outside its scratch folder, removed by `finish` only when every step passed.
remove_on_pass() { CLEANUP+=("$1 $2"); }

cleanup_one() {
    local kind=$1 what=$2
    case "$kind" in
        worktree) g worktree remove --force "$what" >/dev/null ;;
        branch) g branch -D "$what" >/dev/null ;;
        *) echo "    unknown cleanup kind '$kind'"; return 1 ;;
    esac
}

finish() {
    local cost item kept=()
    cost=$( [ -n "$ID" ] && wb "$T_WB" log "$ID" --json 2>/dev/null | py "e=[x['data'] for x in lines if x['kind']=='turn.ended']
print('%.4f USD over %d turn(s)' % (sum(x.get('cost_usd') or 0 for x in e), len(e)))")

    echo
    echo "commands run:"
    sed 's/^/  /' "$SCRATCH/commands"
    echo "cost of the real turn: ${cost:-none} (cap $BUDGET_USD USD, model $MODEL)"
    [ -n "$THREAD_DIR" ] && echo "thread log kept: $THREAD_DIR"

    if [ ${#FAILED[@]} -eq 0 ]; then
        if [ "$SABOTAGE" = cleanup ]; then
            echo "    VERIFY_CLI_SABOTAGE=cleanup: removing a checkout that does not exist"
            CLEANUP+=("worktree $SCRATCH/no-such-checkout")
        fi
        for item in ${CLEANUP[@]+"${CLEANUP[@]}"}; do
            check "cleanup: remove ${item%% *} ${item#* }" "it is still there" cleanup_one "${item%% *}" "${item#* }" \
                || kept+=("$item")
        done
    else
        kept=(${CLEANUP[@]+"${CLEANUP[@]}"})
    fi

    if [ ${#FAILED[@]} -eq 0 ]; then
        rm -rf "$SCRATCH"
        echo "removed: $(IFS=','; echo "${CLEANUP[*]-nothing}"), $SCRATCH"
        echo "RESULT: PASS (${#PASSED[@]} steps)"
        exit 0
    fi
    echo "kept for a look: ${kept[*]-nothing else}, $SCRATCH"
    for item in ${kept[@]+"${kept[@]}"}; do
        case "${item%% *}" in
            worktree) echo "  remove with: git worktree remove --force ${item#* }" ;;
            branch) echo "  remove with: git branch -D ${item#* }" ;;
        esac
    done
    echo "  remove with: rm -rf $SCRATCH"
    echo "RESULT: FAIL (${#FAILED[@]} of $(( ${#PASSED[@]} + ${#FAILED[@]} ))): $(IFS=';'; echo "${FAILED[*]}")"
    exit 1
}
