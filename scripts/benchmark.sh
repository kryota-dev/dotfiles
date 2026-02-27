#!/bin/bash
set -euo pipefail

ITERATIONS=${1:-10}

echo "=== Zsh Startup Benchmark ==="
echo "Iterations: ${ITERATIONS}"
echo ""

# First run (cold start)
echo "Cold start:"
/usr/bin/time zsh -i -c exit 2>&1

echo ""
echo "Average (${ITERATIONS} runs):"

total=0
for i in $(seq 1 "${ITERATIONS}"); do
  # Use zsh's built-in time format
  elapsed=$( { /usr/bin/time zsh -i -c exit; } 2>&1 | grep real | awk '{print $1}' | sed 's/[^0-9.]//g' )
  if [ -n "$elapsed" ]; then
    total=$(echo "$total + $elapsed" | bc)
    printf "  Run %2d: %ss\n" "$i" "$elapsed"
  fi
done

if [ "${ITERATIONS}" -gt 0 ]; then
  avg=$(echo "scale=3; $total / ${ITERATIONS}" | bc)
  echo ""
  echo "Average: ${avg}s"
  echo "Total:   ${total}s"
fi
