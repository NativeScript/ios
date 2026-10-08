# TestRunner AOT stubs

`NativeScriptAOTStubs.m` is generated from `aot-config.json` and compiled into the TestRunner executable, where the runtime finds `__ns_register_aot_calls` with `dlsym` (the symbol is listed in `TestFixtures/exported-symbols.txt`). `AOTDirectCallsTests.js` exercises it.

Regenerate after changing the config, the fixtures or the generator:

```sh
python3 scripts/generate-aot.py TestRunner/AOT/aot-config.json -m <metadata-json>/arm64 -o TestRunner/AOT/NativeScriptAOTStubs.m --report
```

`<metadata-json>` is the directory the metadata generator writes when the TestRunner is built with `NS_JSON_METADATA_PATH=<metadata-json>` set (see `metadata-generator/build-step-metadata-generator.py`).

The config's trailing entries are deliberately unsupported (initializer, NSError out-parameter, variadic, block, typed pointer, unknown selector or class) so the generator's skip paths stay covered.
