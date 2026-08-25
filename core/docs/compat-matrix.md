# Compatibility matrix

Every Dart package/library touched, its compat tier, what broke, what was done. Populated from M5
onward (corpus sweep); kept here from the start so the format is settled before volume hits.

Tiers: T0 (byte-identical behavior) … T5 (does not work, documented why).

| Package/library | Tier | What diverged | Notes |
|---|---|---|---|
| `dart:core` / `dart:isolate` — shared-memory concurrency | n/a | **No upstream counterpart exists to diverge from.** Dart's concurrency model is isolates with no shared mutable memory, so upstream Dart has no atomics API at any layer — not in `dart:core`, not in `dart:isolate`, and `dart:ffi` never added one. | ADR-0055 (`Atomic.*`) and ADR-0056 (`fence(Ordering.…)`) are therefore pure DCDart extensions in `dc:core.bare`, not reimplementations. No upstream Dart program can call them and none can break on them. Recorded because the natural assumption — "surely `dart:ffi` has atomics" — is wrong, and a porting agent that assumes otherwise will look for a mapping that does not exist. |
| `dart:core` — `String.length` | **T3** | **`"héllo".length` is 6 in DCDart and 5 in upstream Dart.** Dart counts UTF-16 code units; DCDart's `Str.length` counts UTF-8 bytes. | ADR-0053. This is the largest deliberate semantic divergence in the language so far, and the most dangerous shape a divergence can take: **silently correct for pure ASCII, silently wrong at the first non-ASCII byte.** It will pass hand-written tests and fail in the field. `Str` is a distinct type (`extension type const Str(String)`) rather than an alias specifically so that `dart:core`'s `String.length` cannot be reached by accident — an earlier attempt exposed `.length` on plain `String` and the frontend resolved it to the upstream getter, returning code units, with no error anywhere. Asserted twice in `tests/conformance/str/`: at runtime, and on the emitted IR (a `[5 x i8]` global would mean the literal was *measured* in code units, not merely reported as such). |
| _(no upstream package run through the compiler yet — the corpus sweep is M5)_ | | | |
