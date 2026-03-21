#!/usr/bin/env bash
# package.sh — creates uploadable ZIP files for each OCI Function
#
# Usage:
#   chmod +x package.sh
#   ./package.sh
#
# Output: dist/ directory containing one zip per function
set -euo pipefail

DIST_DIR="dist"
mkdir -p "$DIST_DIR"

package_fn() {
  local fn_dir="$1"
  local fn_name
  fn_name=$(basename "$fn_dir")
  local zip_path="$DIST_DIR/${fn_name}.zip"

  echo "Packaging $fn_name..."

  # Build zip from inside the function directory so paths are flat (no subdir)
  (
    cd "$fn_dir"
    zip -r "../$zip_path" . \
      --exclude "*.pyc" \
      --exclude "__pycache__/*" \
      --exclude ".DS_Store"
  )

  echo "    → $zip_path ($(du -sh "../$zip_path" 2>/dev/null | cut -f1 || du -sh "$zip_path" | cut -f1))"
}

for fn_dir in fn-slack-webhook fn-image-extractor fn-ai-agent fn-slack-reply; do
  package_fn "$fn_dir"
done

echo ""
echo "Done. Upload each zip via:"
echo "  OCI Console → Functions → Applications → split-app → Create function → Upload ZIP"
echo ""
ls -lh "$DIST_DIR"
