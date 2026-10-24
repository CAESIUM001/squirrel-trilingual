# Static French vocabulary

This resource contains 5,000 precomputed Chinese–French translations. It allows common candidates to display French immediately without waiting for the translation model. Unlisted words and sentences still use the installed Apple on-device model.

Chinese keys were selected from the existing static Rime Ice base dictionary (version 2026-09-20), its 8105-character dictionary (version 2026-08-16), and Chinese-key membership checks against the pinned Qingjian English glossary. The selection prioritizes existing everyday terms, the 300 highest-weight single characters, then 2–6-character base entries in descending dictionary weight. Dictionary weights include upstream manual adjustments and are not a statistically uniform frequency corpus.

French text was generated on this Mac using Apple's public Translation framework and its already installed Chinese–French language model. The complete asset received structural checks and common-word spot checks. These are machine translations, and isolated words may be ambiguous without context. No user input history, learned vocabulary, user database, or user sentence contributed to this asset. The model itself is not redistributed.

Sources and attribution:

- Rime Ice and contributors: https://github.com/iDvel/rime-ice ; GPLv3: https://github.com/iDvel/rime-ice/blob/main/LICENSE . Its base dictionary credits the Huayu Yefeng system dictionary, THUOCL (https://github.com/thunlp/THUOCL), the Modern Chinese Common Words list (https://gist.github.com/indiejoseph/eae09c673460aa0b56db), and Tencent word vectors (https://ai.tencent.com/ailab/nlp/zh/download.html), with extensive upstream editorial work.
- Rime Ice's character dictionary credits the Wiktionary General Standard Chinese Characters pinyin index and the BLCU 2.5-billion-character frequency corpus. Original source headers remain in the upstream dictionary files.
- Qingjian and contributors: https://github.com/qingjian-team/qingjian/tree/10e86493d8f1e59a7483c8afdf910d84bd0908a0 ; GPLv3. Only Chinese keys were checked for membership; no English definitions were reused as French translations.

Project generation scripts and additions: Copyright (c) 2026 rime-english-gloss contributors, GPL-3.0-or-later. See the bundled LICENSE.txt. Exact input and output SHA-256 values, rule, counts, and timing are recorded in glossary-fr.provenance.json. Reproduction tools are shipped under tools/french-glossary/ in the source distribution.
