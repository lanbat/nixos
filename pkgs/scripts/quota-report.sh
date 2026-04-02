#!/usr/bin/env bash
# quota-report.sh
#
# Show XFS project quota usage across both Pi storage drives.
# Run on the Pi as root.
set -euo pipefail

echo "===== Drive A: /mnt/storage-a ====="
xfs_quota -x -c "report -pb -h" /mnt/storage-a 2>/dev/null || echo "(not mounted)"

echo ""
echo "===== Drive B: /mnt/storage-b ====="
xfs_quota -x -c "report -pb -h" /mnt/storage-b 2>/dev/null || echo "(not mounted)"

echo ""
echo "===== Drive A usage (df) ====="
df -h /mnt/storage-a 2>/dev/null || true

echo ""
echo "===== Drive B usage (df) ====="
df -h /mnt/storage-b 2>/dev/null || true
