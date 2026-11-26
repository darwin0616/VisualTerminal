#!/bin/zsh
# 依序用多個 seed 讓 gemma 開發同一步，有一個成功就停。
# 用法：tools/dev_seeds.sh steps/xx.md [seed...]（預設 42 1 2）
ROOT=${0:A:h:h}
STEP=$1; shift
if (( $# == 0 )); then SEEDS=(42 1 2); else SEEDS=($@); fi
for s in $SEEDS; do
  python3 "$ROOT/tools/ai_dev.py" "$STEP" --rounds 5 --seed $s && exit 0
done
exit 1
