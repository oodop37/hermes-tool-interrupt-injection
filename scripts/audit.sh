#!/usr/bin/env bash
# Hermes Tool Interrupt Audit Script
# 列出所有已注册工具的中断检查覆盖情况
set -euo pipefail

TOOLS_DIR="${1:-/usr/local/lib/hermes-agent/tools}"

echo "🔍 Hermes Tool Interrupt Audit"
echo "================================"
echo ""

total=0
covered=0
missing=0

for f in "$TOOLS_DIR"/*.py; do
    fname=$(basename "$f")
    if grep -q "registry.register(" "$f" 2>/dev/null; then
        total=$((total + 1))
        has_int=$(grep -c "is_interrupted" "$f" 2>/dev/null || echo 0)
        if [ "$has_int" -gt 0 ]; then
            echo "  ✅ $fname ($has_int check(s))"
            covered=$((covered + 1))
        else
            echo "  ❌ $fname — NO INTERRUPT CHECK"
            missing=$((missing + 1))
        fi
    fi
done

echo ""
echo "================================"
echo "📊 Summary: $total tools total"
echo "  ✅ Covered: $covered"
echo "  ❌ Missing: $missing"
echo "  📈 Coverage: $(( covered * 100 / total ))%"
