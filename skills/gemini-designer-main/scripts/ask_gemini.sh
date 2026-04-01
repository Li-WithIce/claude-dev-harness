#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ask_gemini.sh [options] "<task text>"

The first non-flag argument is the task text (or use -t / --task, or pipe from stdin).

Options:
  -t, --task <text>            Request text (alternative to positional arg)
  -f, --file <path>            Attach a context file (repeatable)
  -o, --output <path>          Output markdown report path (default: auto-generated)
  -h, --help                   Show this help

Output (on success):
  output_path=<file>           Path to generated markdown report

Examples:
  ask_gemini.sh "Review the current task and produce a test report."
  ask_gemini.sh "Validate the auth changes and conclude pass/fail/blocked." \
    --file docs/task-123/spec.md \
    --file docs/task-123/plan.md \
    --file docs/task-123/review.md \
    -o docs/task-123/test.md
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: $1" >&2
    exit 1
  fi
}

append_file_context() {
  local path="$1"
  local resolved

  if [[ ! -f "$path" ]]; then
    echo "[ERROR] Context file not found: $path" >&2
    exit 1
  fi

  resolved="$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"

  {
    printf '\n\n===== BEGIN FILE: %s =====\n' "$resolved"
    cat "$path"
    printf '\n===== END FILE: %s =====\n' "$resolved"
  } >> "$prompt_file"
}

strip_outer_fences() {
  sed '1{/^```[[:alnum:]_-]*[[:space:]]*$/d;}' | sed '${/^```[[:space:]]*$/d;}'
}

task_text=""
output_path=""
context_files=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--task)
      task_text="${2:-}"
      shift 2
      ;;
    -f|--file)
      context_files+=("${2:-}")
      shift 2
      ;;
    -o|--output)
      output_path="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$task_text" ]]; then
        task_text="$1"
        shift
      else
        echo "[ERROR] Unknown argument: $1" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

require_cmd curl
require_cmd jq

api_key=""

if [[ -n "${ZENMUX_API_KEY:-}" ]]; then
  api_key="$ZENMUX_API_KEY"
fi

if [[ -z "$api_key" ]]; then
  for candidate in ".env.local" "../.env.local" "../../.env.local"; do
    if [[ -f "$candidate" ]]; then
      found="$(grep -E '^ZENMUX_API_KEY=' "$candidate" 2>/dev/null | head -1 | cut -d= -f2-)"
      found="${found//\'/}"
      found="${found//\"/}"
      if [[ -n "$found" ]]; then
        api_key="$found"
        break
      fi
    fi
  done
fi

if [[ -z "$api_key" && -f "$HOME/.config/gemini-designer/api_key" ]]; then
  api_key="$(tr -d '[:space:]' < "$HOME/.config/gemini-designer/api_key")"
fi

if [[ -z "$api_key" ]]; then
  echo "[ERROR] No API key found." >&2
  echo "Set ZENMUX_API_KEY, or add it to .env.local, or save to ~/.config/gemini-designer/api_key" >&2
  exit 1
fi

base_url="${ZENMUX_BASE_URL:-https://zenmux.ai/api/v1}"
base_url="${base_url%/}"
model="${ZENMUX_MODEL:-google/gemini-3.1-pro-preview}"

if [[ -z "$task_text" && ! -t 0 ]]; then
  task_text="$(cat)"
fi

if [[ -z "$task_text" ]]; then
  echo "[ERROR] No task provided. Pass as first argument, use --task, or pipe from stdin." >&2
  exit 1
fi

if [[ -z "$output_path" ]]; then
  timestamp="$(date -u +"%Y%m%d-%H%M%S")"
  output_dir="${PWD}/.runtime/gemini-test"
  mkdir -p "$output_dir"
  output_path="${output_dir}/${timestamp}-test-report.md"
fi

mkdir -p "$(dirname "$output_path")"

prompt_file="$(mktemp)"
request_file="$(mktemp)"
response_file="$(mktemp)"
trap 'rm -f "$prompt_file" "$request_file" "$response_file"' EXIT

cat > "$prompt_file" <<EOF
Task:
$task_text

Instructions:
- You are a software testing and validation reviewer.
- Work only from the evidence in the task text and attached files.
- Never claim a command, test run, or manual validation happened unless it is explicitly present in the inputs.
- Produce a markdown report only. Do not wrap the whole response in code fences.
- The report must contain these exact headings:
  # Test Report
  ## Summary
  ## Scope
  ## Inputs Reviewed
  ## Test Approach
  ## Findings
  ## Risks / Gaps
  ## Conclusion
- Under "## Conclusion", output exactly one lowercase word on the first non-empty line: pass, fail, or blocked.
- Choose blocked when evidence is insufficient, inputs conflict, or execution cannot be validated confidently.
- Respond in the same language as the task text when practical.
EOF

for path in "${context_files[@]}"; do
  append_file_context "$path"
done

system_prompt="You are a rigorous test verifier for software tasks. Your job is to inspect the provided context and write a structured markdown test report with an evidence-based conclusion. Prefer blocked over guessing. Surface concrete risks, missing evidence, and next validation steps."

jq -n \
  --arg model "$model" \
  --arg system "$system_prompt" \
  --rawfile user "$prompt_file" \
  '{
    model: $model,
    messages: [
      { role: "system", content: $system },
      { role: "user", content: $user }
    ]
  }' > "$request_file"

http_code="$(curl -s -w "%{http_code}" -o "$response_file" \
  -X POST "${base_url}/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${api_key}" \
  --max-time 300 \
  -d @"$request_file")"

if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
  echo "[ERROR] API returned HTTP ${http_code}" >&2
  cat "$response_file" >&2
  exit 1
fi

content="$(jq -r '.choices[0].message.content // empty' < "$response_file")"

if [[ -z "$content" ]]; then
  echo "[ERROR] Empty response from API" >&2
  jq . < "$response_file" >&2
  exit 1
fi

if [[ "$content" == '```'* ]]; then
  content="$(printf "%s\n" "$content" | strip_outer_fences)"
fi

printf "%s\n" "$content" > "$output_path"
echo "output_path=$output_path"
