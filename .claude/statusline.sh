#!/usr/bin/env bash
# Claude Code statusline
# Shows: git branch/dirty | model + effort/thinking | context usage | plan credit used | time to reset
# Managed by the statusline-setup agent.

input=$(cat)

# ANSI colors (bytes embedded directly, no interpretation needed at print time)
RESET=$'\033[0m'
DIM=$'\033[2m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
CYAN=$'\033[36m'

human_tokens() {
  local n="$1"
  if [ -z "$n" ] || [ "$n" = "null" ]; then
    echo ""
    return
  fi
  if [ "$n" -ge 1000 ] 2>/dev/null; then
    awk -v n="$n" 'BEGIN{printf "%.0fk", n/1000}'
  else
    echo "$n"
  fi
}

parts=()

# --- 1. Git branch + dirty indicator ---
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
if [ -n "$cwd" ] && git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
  [ -z "$branch" ] && branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
      parts+=("${YELLOW}${branch}*${RESET}")
    else
      parts+=("${GREEN}${branch}${RESET}")
    fi
  fi
fi

# --- 2. Model name + effort/thinking level ---
model=$(echo "$input" | jq -r '.model.display_name // empty')
effort=$(echo "$input" | jq -r '.effort.level // empty')
thinking=$(echo "$input" | jq -r '.thinking.enabled // false')
if [ -n "$model" ]; then
  if [ -n "$effort" ]; then
    parts+=("${CYAN}${model} - ${effort}${RESET}")
  elif [ "$thinking" = "true" ]; then
    parts+=("${CYAN}${model} - thinking${RESET}")
  else
    parts+=("${CYAN}${model}${RESET}")
  fi
fi

# --- 3. Context window usage (always shown, even when empty) ---
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
[ -z "$used_pct" ] && used_pct=0
used_int=$(printf '%.0f' "$used_pct")
used_tok=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
[ -z "$used_tok" ] && used_tok=0
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
color="$GREEN"
[ "$used_int" -ge 70 ] && color="$YELLOW"
[ "$used_int" -ge 90 ] && color="$RED"
tok_str=""
h_used=$(human_tokens "$used_tok")
h_size=$(human_tokens "$ctx_size")
if [ -n "$h_used" ] && [ -n "$h_size" ]; then
  tok_str=" (${h_used}/${h_size})"
fi
parts+=("${color}Ctx ${used_int}%${tok_str}${RESET}")

# --- 4. Plan credit usage (5h rolling window, plus 7d if available) ---
# This is the real plan-credit consumption (what reaches your limit and what
# climbs slower on cheaper models like Fable), not the API-dollar equivalent.
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
usage_seg=""
if [ -n "$five_pct" ]; then
  used=$(printf '%.0f' "$five_pct")
  color="$GREEN"
  [ "$used" -ge 70 ] && color="$YELLOW"
  [ "$used" -ge 90 ] && color="$RED"
  usage_seg="${color}${used}% used (5h)${RESET}"
fi
if [ -n "$week_pct" ]; then
  week_used=$(printf '%.0f' "$week_pct")
  if [ -n "$usage_seg" ]; then
    usage_seg="${usage_seg} ${DIM}/ ${week_used}% used (7d)${RESET}"
  else
    color="$GREEN"
    [ "$week_used" -ge 70 ] && color="$YELLOW"
    [ "$week_used" -ge 90 ] && color="$RED"
    usage_seg="${color}${week_used}% used (7d)${RESET}"
  fi
fi
[ -n "$usage_seg" ] && parts+=("$usage_seg")

# --- 5. Time remaining until session reset ---
resets_at=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // .rate_limits.seven_day.resets_at // empty')
if [ -n "$resets_at" ]; then
  now=$(date +%s)
  remaining=$((resets_at - now))
  if [ "$remaining" -gt 0 ]; then
    h=$((remaining / 3600))
    m=$(((remaining % 3600) / 60))
    if [ "$h" -gt 0 ]; then
      reset_str="${h}h${m}m"
    else
      reset_str="${m}m"
    fi
    parts+=("${DIM}resets in ${reset_str}${RESET}")
  fi
fi

# --- Join and print ---
sep=" ${DIM}|${RESET} "
output=""
for p in "${parts[@]}"; do
  if [ -z "$output" ]; then
    output="$p"
  else
    output="${output}${sep}${p}"
  fi
done

printf '%s\n' "$output"