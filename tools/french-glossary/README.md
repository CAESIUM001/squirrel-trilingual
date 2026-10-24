# Bundled French vocabulary generation

These tools prepare a static Chinese–French vocabulary before the input method is built. They never read the user's learned vocabulary, composition, or input history. Generation runs locally with the installed Apple Translation Chinese–French model on macOS 15 or later; it does not download a model automatically.

1. Run `select_words.py --base <static cn_dicts/base.dict.yaml> --characters <static cn_dicts/8105.dict.yaml> --english <static glossary-en.tsv> --output inputs.json`.
2. Compile `GeneratingTranslator.swift` and `GenerateFrenchGlossary.swift` with `xcrun swiftc -parse-as-library -O -target arm64-apple-macos15.0` and a writable module cache directory.
3. Run the executable with `inputs.json translations.json`. The generator translates in batches of 16, checkpoints only the selected static source terms and their translations, and resumes an existing output file. It must run outside a sandbox that denies access to the local Translation service.
4. Keep nonempty outputs containing French/Latin letters and no Han characters, collapse output whitespace, and write Chinese + tab + French with sorted unique Chinese keys. This excludes untranslated outputs and foreign proper names that the model leaves in Chinese.
5. Include `glossary-fr.tsv`, `glossary-fr.provenance.json`, and `glossary-fr.README.md` in the frontend's Resources. The runtime reads this asset without using or modifying input history.

`GeneratingTranslator.swift` is a frozen generation-only copy of the 0.3.0 translation service used for this asset. It is intentionally independent of later runtime scheduling changes. The source, script, and generated vocabulary additions are distributed with this project's GPLv3 license. The Chinese source dictionaries and their upstream contributor/source notices are credited in the resource provenance and README.
