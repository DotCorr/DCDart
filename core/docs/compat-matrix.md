# Compatibility matrix

Every Dart package/library touched, its compat tier, what broke, what was done. Populated from M5
onward (corpus sweep); kept here from the start so the format is settled before volume hits.

Tiers: T0 (byte-identical behavior) … T5 (does not work, documented why).

| Package/library | Tier | What diverged | Notes |
|---|---|---|---|
| `dart:core` / `dart:isolate` — shared-memory concurrency | n/a | **No upstream counterpart exists to diverge from.** Dart's concurrency model is isolates with no shared mutable memory, so upstream Dart has no atomics API at any layer — not in `dart:core`, not in `dart:isolate`, and `dart:ffi` never added one. | ADR-0055 (`Atomic.*`) and ADR-0056 (`fence(Ordering.…)`) are therefore pure DCDart extensions in `dc:core.bare`, not reimplementations. No upstream Dart program can call them and none can break on them. Recorded because the natural assumption — "surely `dart:ffi` has atomics" — is wrong, and a porting agent that assumes otherwise will look for a mapping that does not exist. |
| _(no upstream package run through the compiler yet — the corpus sweep is M5)_ | | | |
