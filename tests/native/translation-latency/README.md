# French display latency checks

`run.py` builds an isolated helper bundle with the shipped 5,000-entry French dictionary and the actual translator source. It translates fixed examples with Apple's installed on-device model and measures initial results, complete results, synchronous dictionary/cache counts, and progress callbacks. It never starts or registers an input method.

```sh
python3 tests/native/translation-latency/run.py
```

The first case must find all nine common words in the static dictionary; the second must find eight words immediately while a new sentence needs translation; the third must find all nine in memory. Results are recorded with source and dictionary hashes in `results.json`.

Observed in this run: first dictionary load plus nine common words ~3.3 ms; eight cached words alongside a new sentence ~8.7 ms; the new sentence completed by ~129 ms; repeated lookup ~0.003 ms. These measurements exclude the host input field and panel rendering. The model service may already be warm and individual timings vary.

`baseline-0.3.0.json` uses the frozen 0.3.0 backend (SHA256 13902e0a9f132afa1a39920067fb852ba9787cc98741b1c8e69fa02bb306c749): all nine common words arrived together at ~91 ms, then the controller separately imposed its 300 ms debounce. The optimized controller shows dictionary/cache hits immediately and waits 80 ms only for missing translations. Do not describe this as a faster Apple model: first-visible-result behavior and lookup are the changes.
