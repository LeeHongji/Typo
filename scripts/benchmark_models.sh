#!/bin/bash
# Benchmark ARK models for smart direct (typo correction) use case
# Tests response time and output quality for each model

API_KEY="${ARK_API_KEY:?Error: please set ARK_API_KEY environment variable}"
BASE_URL="https://ark.cn-beijing.volces.com/api/v3"

MODELS=(
  "doubao-seed-2.0-lite"
  "doubao-seed-2.0-pro"
  "doubao-seed-2.0-code"
  "doubao-seed-code"
  "kimi-k2.5"
  "glm-4.7"
  "deepseek-v3.2"
  "minimax-m2.5"
)

PROMPT='你是一个语音转写纠错助手。请修正以下语音识别文本中的错别字和标点符号。
规则:
1. 只修正明显的同音/近音错别字
2. 补充或修正标点符号，使句子通顺
3. 不要改变原文的意思、语气和用词风格
4. 不要添加、删除或重组任何内容
5. 直接返回修正后的文本，不要任何解释

{text}'

# Test cases with intentional typos
declare -a TEST_NAMES
declare -a TEST_INPUTS
declare -a TEST_EXPECTED

TEST_NAMES[0]="短句(17字)"
TEST_INPUTS[0]="我今天去了一个很漂亮的地放哪里的风景真的很好看"
TEST_EXPECTED[0]="我今天去了一个很漂亮的地方，那里的风景真的很好看。"

TEST_NAMES[1]="中句(40字)"
TEST_INPUTS[1]="昨天我和朋友去了一个新开的参观吃饭感觉味道还不错就是价格有点贵我觉的下次可以在去试试"
TEST_EXPECTED[1]="昨天我和朋友去了一个新开的餐馆吃饭，感觉味道还不错，就是价格有点贵。我觉得下次可以再去试试。"

TEST_NAMES[2]="长句(80字)"
TEST_INPUTS[2]="今天开会的时候领导说我们下个季度的木标是要把销售额提高百分之二十我觉的这个木标还是有点高的不过如果大家一起努力的话应该还是有可能完成的我们需要从几个方面来入手"
TEST_EXPECTED[2]="今天开会的时候，领导说我们下个季度的目标是要把销售额提高百分之二十。我觉得这个目标还是有点高的，不过如果大家一起努力的话，应该还是有可能完成的。我们需要从几个方面来入手。"

echo "================================================================"
echo "  Type4Me Smart Direct Mode - Model Benchmark"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"
echo ""
echo "Test cases:"
for i in 0 1 2; do
  echo "  [$i] ${TEST_NAMES[$i]}: ${TEST_INPUTS[$i]}"
  echo "      Expected: ${TEST_EXPECTED[$i]}"
  echo ""
done
echo "================================================================"

# Results file
RESULTS_FILE="/tmp/type4me_benchmark_results.txt"
> "$RESULTS_FILE"

for model in "${MODELS[@]}"; do
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Model: $model"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  model_total_ms=0
  model_tests=0

  for i in 0 1 2; do
    input="${TEST_INPUTS[$i]}"
    full_prompt="${PROMPT/\{text\}/$input}"

    # Build JSON request
    json_body=$(python3 -c "
import json
print(json.dumps({
    'model': '$model',
    'messages': [{'role': 'user', 'content': '''$full_prompt'''}],
    'stream': False
}, ensure_ascii=False))
")

    echo ""
    echo "  Test $i: ${TEST_NAMES[$i]}"

    # Time the request
    start_ms=$(python3 -c "import time; print(int(time.time()*1000))")

    response=$(curl -s -w "\n%{http_code}" --max-time 60 \
      -X POST "$BASE_URL/chat/completions" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d "$json_body" 2>/dev/null)

    end_ms=$(python3 -c "import time; print(int(time.time()*1000))")
    elapsed=$((end_ms - start_ms))

    # Extract HTTP code (last line) and body (everything before)
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ]; then
      # Extract content from response
      content=$(echo "$body" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    c = d['choices'][0]['message']['content']
    # Extract usage
    u = d.get('usage', {})
    prompt_tokens = u.get('prompt_tokens', '?')
    completion_tokens = u.get('completion_tokens', '?')
    print(f'{c}|||{prompt_tokens}|||{completion_tokens}')
except Exception as e:
    print(f'PARSE_ERROR: {e}')
" 2>/dev/null)

      result_text=$(echo "$content" | cut -d'|||' -f1)
      prompt_tokens=$(echo "$content" | cut -d'|||' -f2)
      completion_tokens=$(echo "$content" | cut -d'|||' -f3)

      echo "  Time: ${elapsed}ms | Tokens: ${prompt_tokens}→${completion_tokens}"
      echo "  Output: $result_text"
      echo "  Expected: ${TEST_EXPECTED[$i]}"

      model_total_ms=$((model_total_ms + elapsed))
      model_tests=$((model_tests + 1))
    else
      echo "  FAILED: HTTP $http_code (${elapsed}ms)"
      error_msg=$(echo "$body" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('error', {}).get('message', d.get('message', 'unknown')))
except:
    print(sys.stdin.read()[:200])
" 2>/dev/null)
      echo "  Error: $error_msg"
    fi
  done

  if [ $model_tests -gt 0 ]; then
    avg=$((model_total_ms / model_tests))
    echo ""
    echo "  Average: ${avg}ms over $model_tests tests"
    echo "$model|${avg}ms|$model_tests/3 passed" >> "$RESULTS_FILE"
  else
    echo ""
    echo "  All tests failed"
    echo "$model|FAILED|0/3 passed" >> "$RESULTS_FILE"
  fi
done

echo ""
echo ""
echo "================================================================"
echo "  SUMMARY"
echo "================================================================"
printf "%-25s %-12s %-10s\n" "Model" "Avg Time" "Tests"
echo "-----------------------------------------------"
while IFS='|' read -r model time tests; do
  printf "%-25s %-12s %-10s\n" "$model" "$time" "$tests"
done < "$RESULTS_FILE"
echo "================================================================"
