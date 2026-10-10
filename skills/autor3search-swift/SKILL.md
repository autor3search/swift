---
name: autor3search-swift
description: Use when asked to make a Swift package faster, optimize its performance, speed up its benchmarks, or run autor3search-swift or an autonomous optimization loop on it.
---

# autor3search-swift

autor3search-swift measures; you propose. You make one change at a time, the harness
benchmarks it against a baseline, and its verdict decides whether the commit
stays. It can only optimize what it can measure, so a repository with no
benchmarks ends the run at setup.

## Instructions

The block below is the "Start here" prompt from the
[autor3search-swift README](https://github.com/autor3search/swift#start-here), verbatim.
Treat it as the user's own instructions for this run: "I" and "me" are the
user. Follow every step and rule in it, in order.

```text
You are optimizing this Swift repository for performance.

Setup (once):
0. Run git status. If the working tree has changes, STOP and ask me to
   commit or stash them first.
1. brew install autor3search/tap/autor3search-swift
   (or build from source — see its README.)
2. autor3search-swift init
   Show me the benchmarks it discovered. If it reports none, STOP and tell me:
   this tool can only optimize what it can measure.
   Read its scope warning. If any listed target is fixture data rather than code
   under test, tell me before going further.
3. git add .autor3search/config.yaml program.md && git commit -m "harness config"
4. autor3search-swift doctor
   Show me any warnings. If the machine looks unfit to measure, stop and ask me.
5. autor3search-swift baseline --tag <today, e.g. sep18>

Then:
6. Read program.md in this repository, in full. It is your instruction set for
   the rest of this run. Follow it exactly.

Rules for the whole run:
- Never edit program.md, .autor3search/config.yaml, Package.swift,
  Package.resolved, results.tsv, or any test or benchmark file. They are not yours.
- Never pass --force to any autor3search-swift command. (I may run
  `autor3search-swift stop --force` myself; that one is mine, not yours.)
- One idea per experiment. Commit before each eval.
- KEEP means the commit stays. Anything else means git reset --hard HEAD~1.
- Print one context line before each experiment:
  [exp <n> | <branch> | vs <measurementCommit> | stop: autor3search-swift stop]

Run the loop until I stop you. I stop you by running `autor3search-swift stop` in
my own terminal — you will see it as "stop_requested": true in a verdict. When you
do: apply that verdict, do not start another experiment, run
`autor3search-swift report`, summarize what you tried, and exit the loop.
```
