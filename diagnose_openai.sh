#!/usr/bin/env bash
# Diagnose why GPT51PipelineTests fails.
# Usage:  bash diagnose_openai.sh

set +e
cd "$(dirname "$0")"

echo "════════════════════════════════════════════════════"
echo " 1. Shell environment"
echo "════════════════════════════════════════════════════"
echo "Shell:    $SHELL"
echo "PWD:      $(pwd)"
echo "PATH has xcodebuild: $(command -v xcodebuild || echo NOT FOUND)"

echo ""
echo "════════════════════════════════════════════════════"
echo " 2. Key file"
echo "════════════════════════════════════════════════════"
if [ -f ~/.openai_key.sh ]; then
    echo "✓ ~/.openai_key.sh exists"
    perms=$(stat -f '%A' ~/.openai_key.sh)
    echo "  Permissions: $perms (should be 600)"
    if grep -q "PASTE_YOUR" ~/.openai_key.sh; then
        echo "  ✗ STILL HAS PLACEHOLDER — edit the file:"
        echo "     open -e ~/.openai_key.sh"
        exit 1
    fi
    echo "  ✓ Placeholder replaced"
else
    echo "✗ ~/.openai_key.sh NOT FOUND"
    exit 1
fi

echo ""
echo "════════════════════════════════════════════════════"
echo " 3. Load key into THIS script's env"
echo "════════════════════════════════════════════════════"
source ~/.openai_key.sh
if [ -z "$OPENAI_API_KEY" ]; then
    echo "✗ OPENAI_API_KEY is empty after sourcing"
    exit 1
fi
echo "✓ Loaded: ${OPENAI_API_KEY:0:15}... (length=${#OPENAI_API_KEY})"

echo ""
echo "════════════════════════════════════════════════════"
echo " 4. Sanity-check key with a $0.0001 OpenAI call"
echo "════════════════════════════════════════════════════"
http_code=$(curl -sS -o /tmp/openai_ping.json -w "%{http_code}" \
    https://api.openai.com/v1/models \
    -H "Authorization: Bearer $OPENAI_API_KEY")
echo "HTTP $http_code"
if [ "$http_code" = "200" ]; then
    echo "✓ Key is valid"
    echo "  Has gpt-5.1?  $(grep -c '"gpt-5.1"' /tmp/openai_ping.json) match(es)"
else
    echo "✗ Key invalid or rate-limited:"
    cat /tmp/openai_ping.json | head -20
    exit 1
fi

echo ""
echo "════════════════════════════════════════════════════"
echo " 5. Run the failing test, capture full log"
echo "════════════════════════════════════════════════════"
LOG=/tmp/gpt51_diagnose.log
echo "Running xcodebuild test (this takes ~30–60s)..."
echo "Full log → $LOG"

xcodebuild test \
    -project GlassesNotes.xcodeproj \
    -scheme GlassesNotes \
    -destination 'platform=iOS Simulator,id=E01584D0-38FD-45A4-9575-1EEC332F1A61' \
    -only-testing:GlassesNotesTests/GPT51PipelineTests/test_Step1_AnalyzeJSON \
    > "$LOG" 2>&1
rc=$?

echo ""
echo "── xcodebuild exit code: $rc ──"
echo ""
echo "── Test verdict ──"
grep -E "Test Case '|Test Suite '" "$LOG" | tail -5
echo ""
echo "── Errors / skips (if any) ──"
grep -B1 -A3 -iE "error:|XCTSkip|未设置|exception|FAIL" "$LOG" | head -40 || echo "(none found)"
echo ""
echo "── OpenAI calls in log ──"
grep -E "\[OpenAI" "$LOG" | head -10 || echo "(no [OpenAI] log lines — test never reached the API call)"

echo ""
echo "════════════════════════════════════════════════════"
echo " Full log: cat $LOG"
echo "════════════════════════════════════════════════════"
