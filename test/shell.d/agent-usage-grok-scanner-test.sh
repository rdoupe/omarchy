#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command jq
require_command python3

# One turn_completed notification, the only Grok session update that carries a
# usage block. Everything else in updates.jsonl is stream noise the scanner
# must walk past.
turn() {
  local prompt_id="$1" stamp="$2" usage="$3"
  jq -cn --arg id "$prompt_id" --argjson ts "$stamp" --argjson usage "$usage" \
    '{timestamp: $ts, method: "_x.ai/session/update", params: {sessionId: "s", update: {sessionUpdate: "turn_completed", prompt_id: $id, usage: $usage}}}'
}

now=$(date +%s)

TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

session="$TEST_HOME/.grok/sessions/%2Fhome%2Fuser/01a0-aaaa"
mkdir -p "$session"

# Grok reports totalTokens == inputTokens + outputTokens: cachedReadTokens and
# cacheCreationTokens are a subset of inputTokens, and reasoningTokens a subset
# of outputTokens. 100 input (60 cached, 10 written) + 20 output = 120 total.
{
  turn "p1" "$now" '{"inputTokens":100,"outputTokens":20,"totalTokens":120,"cachedReadTokens":60,"cacheCreationTokens":10,"reasoningTokens":8,"modelUsage":{"grok-test":{"inputTokens":100,"outputTokens":20,"totalTokens":120,"cachedReadTokens":60,"cacheCreationTokens":10,"reasoningTokens":8}}}'
  echo '{"timestamp":0,"method":"_x.ai/session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_delta","text":"turn_completed is a substring here"}}}'
} >"$session/updates.jsonl"

result=$(HOME="$TEST_HOME" GROK_HOME="$TEST_HOME/.grok" XDG_CACHE_HOME="$TEST_HOME/.cache" \
  XDG_CONFIG_HOME="$TEST_HOME/.config" XDG_DATA_HOME="$TEST_HOME/.local/share" \
  GROK_API_BASE_URL="http://127.0.0.1:1/v1" "$ROOT/bin/omarchy-agent-usage-grok" 2>/dev/null)

[[ $(jq -r '.todayTotalTokens' <<<"$result") == "120" ]] ||
  fail "Grok collector counts each turn once" "$result"
pass "Grok collector counts each turn once"

[[ $(jq -c '.modelUsage["grok-test"]' <<<"$result") == '{"inputTokens":30,"outputTokens":20,"cacheReadInputTokens":60,"cacheCreationInputTokens":10}' ]] ||
  fail "Grok collector does not double-count cache or reasoning tokens" "$result"
pass "Grok collector does not double-count cache or reasoning tokens"

[[ $(jq -r '.id + "/" + (.limits|length|tostring) + "/" + (.ready|tostring)' <<<"$result") == "grok/0/true" ]] ||
  fail "Grok collector identifies itself and stays ready without limits" "$result"
pass "Grok collector identifies itself and stays ready without limits"

# An unreachable billing endpoint must not cost the local numbers: the panel
# still gets today's tokens, plus the text explaining the missing ledger.
[[ -n $(jq -r '.authHelpText' <<<"$result") ]] ||
  fail "Grok collector explains why the ledger is missing" "$result"
pass "Grok collector falls back to local stats when the API is unreachable"

# A turn that spends tokens on several models splits across them, but it is
# still one prompt: the panel counts questions asked, not models that answered.
MULTI_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME" "$MULTI_HOME"' EXIT
multi="$MULTI_HOME/.grok/sessions/%2Fhome%2Fuser/01a0-bbbb"
mkdir -p "$multi"
turn "p2" "$now" '{"inputTokens":30,"outputTokens":10,"totalTokens":40,"cachedReadTokens":0,"cacheCreationTokens":0,"modelUsage":{"grok-big":{"inputTokens":20,"outputTokens":6,"cachedReadTokens":0,"cacheCreationTokens":0},"grok-small":{"inputTokens":10,"outputTokens":4,"cachedReadTokens":0,"cacheCreationTokens":0}}}' >"$multi/updates.jsonl"

result=$(HOME="$MULTI_HOME" GROK_HOME="$MULTI_HOME/.grok" XDG_CACHE_HOME="$MULTI_HOME/.cache" \
  XDG_CONFIG_HOME="$MULTI_HOME/.config" XDG_DATA_HOME="$MULTI_HOME/.local/share" \
  GROK_API_BASE_URL="http://127.0.0.1:1/v1" "$ROOT/bin/omarchy-agent-usage-grok" 2>/dev/null)

[[ $(jq -r '.todayPrompts + (.modelUsage|length)' <<<"$result") == "3" ]] ||
  fail "Grok collector counts a multi-model turn as one prompt" "$result"
[[ $(jq -r '.todayTotalTokens' <<<"$result") == "40" ]] ||
  fail "Grok collector splits a multi-model turn without losing tokens" "$result"
pass "Grok collector splits a multi-model turn across models but counts one prompt"

# Resuming or forking a session carries the transcript forward, so the same
# prompt_id can land in two files. Tokens must not be counted twice.
fork="$MULTI_HOME/.grok/sessions/%2Fhome%2Fuser/01a0-cccc"
mkdir -p "$fork"
cp "$multi/updates.jsonl" "$fork/updates.jsonl"

result=$(HOME="$MULTI_HOME" GROK_HOME="$MULTI_HOME/.grok" XDG_CACHE_HOME="$MULTI_HOME/.cache2" \
  XDG_CONFIG_HOME="$MULTI_HOME/.config" XDG_DATA_HOME="$MULTI_HOME/.local/share" \
  GROK_API_BASE_URL="http://127.0.0.1:1/v1" "$ROOT/bin/omarchy-agent-usage-grok" 2>/dev/null)

[[ $(jq -r '.todayTotalTokens' <<<"$result") == "40" ]] ||
  fail "Grok collector dedups a turn replayed into a forked session" "$result"
pass "Grok collector dedups a turn replayed into a forked session"

# Transcripts older than the 30-day window are not read at all.
OLD_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME" "$MULTI_HOME" "$OLD_HOME"' EXIT
old="$OLD_HOME/.grok/sessions/%2Fhome%2Fuser/01a0-dddd"
mkdir -p "$old"
turn "p3" "$((now - 40 * 86400))" '{"inputTokens":500,"outputTokens":500,"cachedReadTokens":0,"cacheCreationTokens":0}' >"$old/updates.jsonl"
touch -d "40 days ago" "$old/updates.jsonl"

result=$(HOME="$OLD_HOME" GROK_HOME="$OLD_HOME/.grok" XDG_CACHE_HOME="$OLD_HOME/.cache" \
  XDG_CONFIG_HOME="$OLD_HOME/.config" XDG_DATA_HOME="$OLD_HOME/.local/share" \
  GROK_API_BASE_URL="http://127.0.0.1:1/v1" "$ROOT/bin/omarchy-agent-usage-grok" 2>/dev/null)

[[ $(jq -r '.totalPrompts' <<<"$result") == "0" ]] ||
  fail "Grok collector ignores transcripts past the 30-day window" "$result"
pass "Grok collector ignores transcripts past the 30-day window"

# A subscription burned entirely through opencode has no native session files;
# usage must come from opencode's message database, filtered to xAI.
OPENCODE_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME" "$MULTI_HOME" "$OLD_HOME" "$OPENCODE_HOME"' EXIT

python3 - "$OPENCODE_HOME/.local/share/opencode/opencode.db" <<'PY'
import json
import sqlite3
import sys
import time
from pathlib import Path

db = Path(sys.argv[1])
db.parent.mkdir(parents=True, exist_ok=True)
conn = sqlite3.connect(db)
conn.execute("CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)")
now_ms = int(time.time() * 1000)

def message(id, provider, model, role="assistant", input=0, output=0, reasoning=0, read=0, write=0):
  return (id, "ses_1", now_ms, now_ms, json.dumps({
    "role": role,
    "providerID": provider,
    "modelID": model,
    "tokens": {"input": input, "output": output, "reasoning": reasoning, "cache": {"read": read, "write": write}},
    "time": {"created": now_ms},
  }))

conn.executemany("INSERT INTO message VALUES (?, ?, ?, ?, ?)", [
  message("msg_1", "xai", "grok-4.6", input=80, output=40, reasoning=5, read=30),
  message("msg_2", "anthropic", "claude-opus-5", input=999, output=999),
  message("msg_3", "xai", "grok-4.6", role="user"),
  message("msg_4", "xai-proxy", "grok-4.6", input=999, output=999),
])
conn.execute("INSERT INTO message VALUES ('msg_5', 'ses_1', ?, ?, '[\"not\",\"an\",\"object\"]')", (now_ms, now_ms))
conn.commit()
conn.close()
PY

result=$(HOME="$OPENCODE_HOME" GROK_HOME="$OPENCODE_HOME/.grok" XDG_CACHE_HOME="$OPENCODE_HOME/.cache" \
  XDG_CONFIG_HOME="$OPENCODE_HOME/.config" XDG_DATA_HOME="$OPENCODE_HOME/.local/share" \
  GROK_API_BASE_URL="http://127.0.0.1:1/v1" "$ROOT/bin/omarchy-agent-usage-grok" 2>/dev/null)

[[ $(jq -r '.todayTotalTokens' <<<"$result") == "155" ]] ||
  fail "Grok collector counts xAI usage, reasoning included, from opencode sessions" "$result"
[[ $(jq -c '.modelUsage' <<<"$result") == '{"grok-4.6":{"inputTokens":80,"outputTokens":45,"cacheReadInputTokens":30,"cacheCreationInputTokens":0}}' ]] ||
  fail "Grok collector ignores prefix-colliding providers, user messages, and malformed rows" "$result"
pass "Grok collector counts xAI usage from opencode sessions"

# The billing endpoint reports an allowance and what has been spent against it.
# Only the ratio is displayable: the figures arrive as bare numbers with no
# unit, so the collector must publish percentages and no balance block.
API_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME" "$MULTI_HOME" "$OLD_HOME" "$OPENCODE_HOME" "$API_HOME"' EXIT
mkdir -p "$API_HOME/.grok"

# An unsigned JWT with a far-future expiry: the collector reads the payload for
# the expiry only, and never verifies the signature it has no key for.
python3 - "$API_HOME/.grok/auth.json" <<'PY'
import base64
import json
import sys
import time
from pathlib import Path

claims = {"exp": int(time.time()) + 3600, "tier": 3}
payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).rstrip(b"=").decode()
Path(sys.argv[1]).write_text(json.dumps({"https://auth.x.ai::client": {"key": f"header.{payload}.signature"}}))
PY

python3 - "$API_HOME/port" <<'PY' &
import http.server
import json
import sys
import threading
from pathlib import Path

BILLING = {"config": {
  "monthlyLimit": {"val": 200},
  "used": {"val": 50},
  "onDemandCap": {"val": 100},
  "billingPeriodStart": "2026-09-01T00:00:00+00:00",
  "billingPeriodEnd": "2026-10-01T00:00:00+00:00",
  "history": [
    {"billingCycle": {"year": 2026, "month": 9}, "includedUsed": {"val": 50}, "onDemandUsed": {"val": 25}, "totalUsed": {"val": 75}},
    {"billingCycle": {"year": 2026, "month": 8}, "includedUsed": {"val": 10}, "onDemandUsed": {"val": 90}, "totalUsed": {"val": 100}},
  ],
}}

class Handler(http.server.BaseHTTPRequestHandler):
  def do_GET(self):
    if not self.headers.get("Authorization", "").startswith("Bearer "):
      self.send_error(401)
      return
    body = BILLING if self.path.endswith("/billing") else {"hasGrokCodeAccess": True}
    raw = json.dumps(body).encode()
    self.send_response(200)
    self.send_header("Content-Type", "application/json")
    self.send_header("Content-Length", str(len(raw)))
    self.end_headers()
    self.wfile.write(raw)

  def log_message(self, *args):
    pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
PY
stub_pid=$!
trap 'kill "$stub_pid" 2>/dev/null; rm -rf "$TEST_HOME" "$MULTI_HOME" "$OLD_HOME" "$OPENCODE_HOME" "$API_HOME"' EXIT

for _ in {1..50}; do
  [[ -s "$API_HOME/port" ]] && break
  sleep 0.1
done
[[ -s "$API_HOME/port" ]] || fail "Grok billing stub starts"

result=$(HOME="$API_HOME" GROK_HOME="$API_HOME/.grok" XDG_CACHE_HOME="$API_HOME/.cache" \
  XDG_CONFIG_HOME="$API_HOME/.config" XDG_DATA_HOME="$API_HOME/.local/share" \
  GROK_API_BASE_URL="http://127.0.0.1:$(cat "$API_HOME/port")/v1" "$ROOT/bin/omarchy-agent-usage-grok" 2>/dev/null)

[[ $(jq -c '[.limits[] | {label, percent, resetsAt}]' <<<"$result") == '[{"label":"Monthly credits","percent":0.25,"resetsAt":"2026-10-01T00:00:00+00:00"},{"label":"On-demand cap","percent":0.25,"resetsAt":"2026-10-01T00:00:00+00:00"}]' ]] ||
  fail "Grok collector reports the billing allowances as percentages" "$result"
pass "Grok collector reports the billing allowances as percentages"

[[ $(jq -r 'has("balance")' <<<"$result") == "false" ]] ||
  fail "Grok collector publishes no balance for a unitless ledger" "$result"
[[ -z $(jq -r '.authHelpText' <<<"$result") ]] ||
  fail "Grok collector reports no auth problem once the ledger loads" "$result"
pass "Grok collector publishes percentages only, with no balance block"

# A plan name has no source in the API, so the hero line comes from config.
mkdir -p "$API_HOME/.config/omarchy/agents"
echo '{"planLabel":"SuperGrok Heavy"}' >"$API_HOME/.config/omarchy/agents/grok.json"

result=$(HOME="$API_HOME" GROK_HOME="$API_HOME/.grok" XDG_CACHE_HOME="$API_HOME/.cache" \
  XDG_CONFIG_HOME="$API_HOME/.config" XDG_DATA_HOME="$API_HOME/.local/share" \
  GROK_API_BASE_URL="http://127.0.0.1:$(cat "$API_HOME/port")/v1" "$ROOT/bin/omarchy-agent-usage-grok" 2>/dev/null)

[[ $(jq -r '.tierLabel' <<<"$result") == "SuperGrok Heavy" ]] ||
  fail "Grok collector takes the plan label from config" "$result"
pass "Grok collector takes the plan label from config"

# An expired token is spotted locally: no request is made, and the record says
# what to do about it. The refresh token beside it is deliberately left alone.
python3 - "$API_HOME/.grok/auth.json" <<'PY'
import base64
import json
import sys
import time
from pathlib import Path

claims = {"exp": int(time.time()) - 60}
payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).rstrip(b"=").decode()
Path(sys.argv[1]).write_text(json.dumps({"https://auth.x.ai::client": {"key": f"header.{payload}.signature", "refresh_token": "keep-me"}}))
PY

result=$(HOME="$API_HOME" GROK_HOME="$API_HOME/.grok" XDG_CACHE_HOME="$API_HOME/.cache3" \
  XDG_CONFIG_HOME="$API_HOME/.config" XDG_DATA_HOME="$API_HOME/.local/share" \
  GROK_API_BASE_URL="http://127.0.0.1:$(cat "$API_HOME/port")/v1" "$ROOT/bin/omarchy-agent-usage-grok" 2>/dev/null)

[[ $(jq -r '.authHelpText' <<<"$result") == *"expired"* && $(jq -r '.limits|length' <<<"$result") == "0" ]] ||
  fail "Grok collector reports an expired sign-in without calling the API" "$result"
[[ $(jq -r '.[].refresh_token' "$API_HOME/.grok/auth.json") == "keep-me" ]] ||
  fail "Grok collector leaves auth.json untouched" "$result"
pass "Grok collector reports an expired sign-in and never spends the refresh token"

# The local-stats cache is a versioned envelope, so a wrong-shaped file is a
# miss that rescans rather than a garbage record.
cache_file=$(ls "$TEST_HOME/.cache/omarchy/agent-usage/"grok-scan-*.json 2>/dev/null | head -n 1)
[[ -n $cache_file && -s $cache_file ]] ||
  fail "Grok collector leaves a cache file behind" "$cache_file"
[[ $(stat -c %a "$cache_file") == "644" ]] ||
  fail "Grok collector keeps cache files readable" "$cache_file"
[[ $(jq -r '.schemaVersion' "$cache_file") == "1" && $(jq -r '.stats.todayTotalTokens' "$cache_file") == "120" ]] ||
  fail "Grok collector writes a versioned cache envelope" "$(cat "$cache_file")"

printf '[]' >"$cache_file"
result=$(HOME="$TEST_HOME" GROK_HOME="$TEST_HOME/.grok" XDG_CACHE_HOME="$TEST_HOME/.cache" \
  XDG_CONFIG_HOME="$TEST_HOME/.config" XDG_DATA_HOME="$TEST_HOME/.local/share" \
  GROK_API_BASE_URL="http://127.0.0.1:1/v1" "$ROOT/bin/omarchy-agent-usage-grok" 2>/dev/null)

[[ $(jq -r '.todayTotalTokens' <<<"$result") == "120" ]] ||
  fail "Grok collector rescans past a corrupt cache" "$result"
pass "Grok collector writes a versioned local-stats cache and rescans past a corrupt one"
