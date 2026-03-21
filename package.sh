#!/usr/bin/env bash
# package.sh — Build a deployment ZIP for each Lambda function.
#
# Builds for the Lambda runtime (linux/x86_64) so compiled extensions like
# grpcio are the correct Linux binaries — not the macOS ones that would be
# installed by a plain `pip install` on a Mac.
#
# boto3 is intentionally excluded: the Lambda Python runtime includes it.
#
# Each ZIP contains:
#   - lambda_function.py
#   - secrets.py  (shared SSM helper)
#   - installed dependencies from requirements.txt (linux/x86_64)
#
# Output: dist/<function-name>.zip
#
# Usage:
#   ./package.sh                      # package all functions
#   ./package.sh fn-slack-webhook     # package one function

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$REPO_ROOT/dist"

FUNCTIONS=(fn-slack-webhook fn-image-extractor fn-ai-agent fn-slack-reply)

if [[ $# -ge 1 ]]; then
  FUNCTIONS=("$1")
fi

mkdir -p "$DIST_DIR"

for fn in "${FUNCTIONS[@]}"; do
  echo ""
  echo "==> Packaging $fn"
  FN_DIR="$REPO_ROOT/$fn"

  if [[ ! -d "$FN_DIR" ]]; then
    echo "ERROR: Directory $FN_DIR not found" >&2
    exit 1
  fi

  BUILD_DIR="$(mktemp -d)"

  # Install deps targeting the Lambda Linux runtime, skipping boto3
  if [[ -f "$FN_DIR/requirements.txt" ]]; then
    # Filter out boto3 — it's provided by the Lambda runtime
    grep -v '^boto3' "$FN_DIR/requirements.txt" > "$BUILD_DIR/filtered_reqs.txt" || true

    if [[ -s "$BUILD_DIR/filtered_reqs.txt" ]]; then
      pip install \
        --quiet \
        --platform manylinux2014_x86_64 \
        --implementation cp \
        --python-version 3.12 \
        --only-binary=:all: \
        --target "$BUILD_DIR" \
        -r "$BUILD_DIR/filtered_reqs.txt"
    fi
  fi

  # Remove files that bloat the ZIP but are never needed at runtime
  find "$BUILD_DIR" -type d -name "tests"       -exec rm -rf {} + 2>/dev/null || true
  find "$BUILD_DIR" -type d -name "test"        -exec rm -rf {} + 2>/dev/null || true
  find "$BUILD_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
  find "$BUILD_DIR" -type d -name "*.dist-info" -exec rm -rf {} + 2>/dev/null || true
  find "$BUILD_DIR" -type d -name "*.egg-info"  -exec rm -rf {} + 2>/dev/null || true
  find "$BUILD_DIR" -name "*.pyc"               -delete 2>/dev/null || true

  # Copy handler and shared helper
  cp "$FN_DIR/lambda_function.py" "$BUILD_DIR/"
  cp "$REPO_ROOT/ssm_secrets.py"      "$BUILD_DIR/"

  OUT_ZIP="$DIST_DIR/${fn}.zip"
  (cd "$BUILD_DIR" && zip -q -r "$OUT_ZIP" .)

  echo "    -> $OUT_ZIP  ($(du -sh "$OUT_ZIP" | cut -f1))"

  rm -rf "$BUILD_DIR"
done

echo ""
echo "Packaging complete. ZIPs are in $DIST_DIR/"
