#!/usr/bin/env python3
"""Select reproducible static vocabulary; never scans user databases or history.
SPDX-License-Identifier: GPL-3.0-or-later
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

PREFERRED = """你好 您好 你好啊 谢谢 谢谢你 不客气 对不起 没关系 再见 早上好 晚上好 下午好 晚安 请问 欢迎 是的 好的 好啊 可以 不可以 没问题 没事 今天 明天 昨天 上午 下午 晚上 现在 以后 一起 我们 你们 他们 学习 图书馆 工作 会议 电脑 手机 键盘 输入法 中文 英文 法语 中国 法国 翻译 苹果 水 水果 咖啡 茶 牛奶 饭 吃饭 喝水 天气 时间 朋友 家人 公司 学校 同学 老师 医生 银行 酒店 机场 火车 飞机 公交车 地铁 出租车 帮忙 快乐 幸福 喜欢 爱 高兴 美丽 非常 为什么 怎么 什么 哪个 哪里 多少 如何""".split()

def parse_dictionary(path):
    terms = {}
    for line in path.read_text().splitlines():
        columns = line.split("\t")
        if len(columns) < 3 or line.startswith("#") or not re.fullmatch("[\u4e00-\u9fff]{1,6}", columns[0]):
            continue
        try:
            weight = int(columns[2])
        except ValueError:
            continue
        terms[columns[0]] = max(terms.get(columns[0], 0), weight)
    return terms

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--characters", type=Path, required=True)
    parser.add_argument("--english", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--count", type=int, default=5000)
    args = parser.parse_args()
    base = parse_dictionary(args.base)
    characters = parse_dictionary(args.characters)
    english = {line.split("\t")[0] for line in args.english.read_text().splitlines() if "\t" in line}
    preferred = [term for term in PREFERRED if term in base or term in characters or term in english]
    ranked = [term for term, _ in sorted(base.items(), key=lambda pair: (-pair[1], pair[0])) if 2 <= len(term) <= 6]
    singles = [term for term, _ in sorted(characters.items(), key=lambda pair: (-pair[1], pair[0])) if len(term) == 1][:300]
    selected = list(dict.fromkeys(preferred + singles + ranked))[:args.count]
    args.output.write_text(json.dumps(selected, ensure_ascii=False))
    print(json.dumps({"count": len(selected), "inputs_sha256": hashlib.sha256(args.output.read_bytes()).hexdigest()}))

if __name__ == "__main__":
    main()
