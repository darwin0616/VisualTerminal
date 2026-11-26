#!/usr/bin/env python3
"""讓本地模型（預設 inkling-2-mini）依需求寫 Mac app 程式碼 → xcodebuild 編譯 → 把錯誤回饋給模型修正。

用法：python3 tools/gemma_dev.py steps/01-chat.md [--rounds 3]

- 目前 iPhoneToolKits/ 內所有 .swift 檔案會附在 prompt 中，模型只需輸出新增或修改的檔案。
- 成功：新檔案留在 iPhoneToolKits/。失敗：iPhoneToolKits/ 內的 .swift 還原成執行前的狀態，失敗版本保存在 runs/。
- 每次執行的完整紀錄在 runs/<時間>-<步驟>/。
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "App" / "VisualTerminal"
RUNS = ROOT / "runs"

CODE_RE = re.compile(r"```(?:swift|Swift)?[ \t]*\n(.*?)```", re.S)
FILE_RE = re.compile(r"^\s*//\s*(?:File|檔案)\s*[:：]\s*([\w.+-]+\.swift)\s*$", re.M)
DIAG_RE = re.compile(r"^(/[^:\n]+\.swift):(\d+):(\d+): (error|warning): (.*)$", re.M)
NEAR_MISS = "nearly matches"
# 這些警告代表程式一定有邏輯錯誤（能編譯但不會照預期執行），視同編譯失敗
FATAL_WARNINGS = (NEAR_MISS, "always fails", "will never be executed")
MAX_ERRORS = 15

FORMAT = """

【作答格式】
- 每個檔案一個 ```swift 程式碼區塊，區塊第一行寫 `// File: 檔名.swift`。
- 只輸出這次新增或修改的檔案，但每個輸出的檔案都必須是**完整內容**，不可省略（不要寫 `...` 或「其餘不變」）。
- 沒有輸出的檔案會保持原樣。
- 程式碼區塊之外可以有簡短說明。"""


def ask(args, messages: list[dict]) -> dict:
    think = False if args.think in ("false", "off") else args.think
    body = {"model": args.model, "messages": messages, "stream": False, "think": think,
            "options": {"temperature": 0, "seed": args.seed, "num_ctx": args.num_ctx,
                        "num_predict": args.num_predict}}
    req = urllib.request.Request(f"{args.host}/api/chat", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=3600) as r:
        d = json.load(r)
    return {"content": d.get("message", {}).get("content", ""), "seconds": round(time.time() - t0, 1),
            "eval_count": d.get("eval_count"), "prompt_eval_count": d.get("prompt_eval_count"),
            "done_reason": d.get("done_reason")}


def extract(text: str) -> dict[str, str]:
    """只抽取第一行附近有 `// File: 檔名.swift` 的程式碼區塊；說明文字中的程式碼片段一律忽略。"""
    files = {}
    for block in CODE_RE.findall(text):
        m = FILE_RE.search("\n".join(block.split("\n")[:3]))
        if block.strip() and m:
            files[m.group(1)] = block
    return files


def current_sources() -> dict[str, str]:
    return {p.name: p.read_text(encoding="utf-8") for p in sorted(SOURCES.glob("*.swift"))}


def write_sources(files: dict[str, str]) -> None:
    for p in SOURCES.glob("*.swift"):
        p.unlink()
    for name, code in files.items():
        (SOURCES / name).write_text(code, encoding="utf-8")


def build() -> tuple[bool, str]:
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=ROOT / "App", check=True)
    p = subprocess.run(["xcodebuild", "-project", "VisualTerminal.xcodeproj", "-scheme", "VisualTerminal",
                        "-destination", "platform=macOS", "-derivedDataPath", "build", "build"],
                       cwd=ROOT / "App", capture_output=True, text=True, timeout=900)
    log = p.stdout + p.stderr
    return p.returncode == 0 and not any(w in log for w in FATAL_WARNINGS), log


def errors_of(log: str, files: dict[str, str]) -> list[str]:
    seen, out = set(), []
    for path, line, _col, level, msg in DIAG_RE.findall(log):
        name = Path(path).name
        if (name, line, msg) in seen or name not in files or (level == "warning" and not any(w in msg for w in FATAL_WARNINGS)):
            continue
        seen.add((name, line, msg))
        lines = files[name].split("\n")
        src = lines[int(line) - 1].strip() if 0 < int(line) <= len(lines) else ""
        out.append(f"{name}:{line}: error: {msg}\n    {src}")
    if not out:  # 連結錯誤等沒有檔名的錯誤
        out = [l for l in log.splitlines() if "error:" in l][:MAX_ERRORS] or [log[-1500:]]
    return out[:MAX_ERRORS]


def repair_prompt(errors: list[str]) -> str:
    return ("用 xcodebuild（Swift 6 語言模式，macOS 15，SwiftUI）編譯失敗，錯誤如下：\n\n```\n" + "\n".join(errors) +
            "\n```\n\n請修正所有錯誤，重新輸出**有錯誤的檔案**的完整內容（格式與之前相同）。\n"
            "錯誤訊息若顯示某個 API 不存在，代表它真的不存在：不要換個相似的名字猜測，"
            "改用你確定存在的基本寫法，或直接移除非必要的修飾。")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("step", type=Path)
    ap.add_argument("--rounds", type=int, default=3, help="編譯失敗後最多修正幾輪")
    ap.add_argument("--model", default="inkling-2-mini")
    ap.add_argument("--host", default="http://localhost:11434")
    ap.add_argument("--system", type=Path, default=ROOT / "prompts" / "macos-v1.txt")
    ap.add_argument("--think", default="minimal", help="thinking：false 或等級（minimal、low…）")
    ap.add_argument("--seed", type=int, default=42, help="換 seed 可得到不同的答案")
    ap.add_argument("--num-ctx", type=int, default=32768)
    ap.add_argument("--num-predict", type=int, default=16384)
    args = ap.parse_args()

    out = RUNS / f"{time.strftime('%Y%m%d-%H%M%S')}-{args.step.stem}-s{args.seed}"
    out.mkdir(parents=True)
    original = current_sources()
    shutil.copytree(SOURCES, out / "src_before")

    ctx = "\n\n".join(f"```swift\n// File: {n}\n{c.rstrip()}\n```" for n, c in original.items())
    user = (args.step.read_text(encoding="utf-8").strip() +
            "\n\n【目前專案的檔案】\n" + (ctx or "（無）") + FORMAT)
    messages = [{"role": "system", "content": args.system.read_text(encoding="utf-8")},
                {"role": "user", "content": user}]
    (out / "prompt.md").write_text(user, encoding="utf-8")

    files = dict(original)
    rounds = []
    ok = False
    for r in range(args.rounds + 1):
        print(f"[第 {r} 輪] 詢問 {args.model}…", flush=True)
        try:
            resp = ask(args, messages)
        except Exception as e:  # 例如 Ollama 記憶體不足回傳 500：還原原始碼並記錄，不要留下半成品
            write_sources(original)
            (out / "result.json").write_text(json.dumps({"step": str(args.step), "model": args.model, "seed": args.seed,
                                                         "ok": False, "error": f"第 {r} 輪呼叫模型失敗：{e}",
                                                         "rounds": rounds}, ensure_ascii=False, indent=2), encoding="utf-8")
            print(f"呼叫模型失敗（{e}）：原始碼已還原，紀錄在 {out}")
            sys.exit(2)
        (out / f"response_r{r}.md").write_text(resp["content"], encoding="utf-8")
        new = extract(resp["content"])
        files.update(new)
        write_sources(files)
        shutil.copytree(SOURCES, out / f"src_r{r}")
        ok, log = build()
        (out / f"build_r{r}.log").write_text(log, encoding="utf-8")
        errs = [] if ok else errors_of(log, files)
        info = {"round": r, "files": sorted(new), "build_ok": ok, "errors": len(errs),
                **{k: resp[k] for k in ("seconds", "eval_count", "prompt_eval_count", "done_reason")}}
        rounds.append(info)
        print(f"  輸出 {sorted(new)}，{resp['seconds']}s，編譯{'成功' if ok else f'失敗（{len(errs)} 個錯誤）'}",
              flush=True)
        if ok:
            break
        (out / f"errors_r{r}.txt").write_text("\n".join(errs), encoding="utf-8")
        # 只帶出錯的檔案與錯誤訊息，不附上整段舊回覆（上下文過大會讓模型耗盡 GPU 記憶體）
        bad = sorted({e.split(":")[0] for e in errs if e.split(":")[0] in files}) or sorted(new)
        ctx_bad = "\n\n".join(f"```swift\n// File: {n}\n{files[n].rstrip()}\n```" for n in bad)
        messages = [messages[0], {"role": "user", "content":
                    args.step.read_text(encoding="utf-8").strip() + "\n\n【目前有錯誤的檔案】\n" + ctx_bad
                    + "\n\n" + repair_prompt(errs) + FORMAT}]

    if not ok:
        write_sources(original)
        print("修正後仍失敗：原始碼已還原，失敗版本在", out)
    (out / "result.json").write_text(json.dumps({"step": str(args.step), "model": args.model, "seed": args.seed, "ok": ok,
                                                 "rounds": rounds}, ensure_ascii=False, indent=2),
                                     encoding="utf-8")
    print("結果：", "成功" if ok else "失敗", out)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
