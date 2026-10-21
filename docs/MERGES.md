# Merges

A merge is a virtual model, `redx-merge-<name>`, that runs several models one after another so they fit in RAM.

| Mode | Models | What happens |
|---|---|---|
| `draft_refine` | exactly 2: drafter, refiner | the drafter answers, then the refiner rewrites it into the final answer |
| `panel_judge` | 2–3 + `judge` | each model answers, then the judge sees all answers and writes the best one |
| `router` | 1–4 | keyword routing: code goes to a `*coder*` model, math/logic to an `r1`/`qwq` model, and the rest to the general model. If the routed model fails, the last model in the list is used |

Reasoning models (R1/QwQ) automatically get at least 2048 tokens so they can finish thinking, and their `<think>` blocks are removed.

Create one from the app (Merges tab) or with the admin API:
```bash
curl 127.0.0.1:8092/admin/merges -H "Authorization: Bearer $ADMIN" \
 -d '{"name":"code-panel","mode":"panel_judge","models":["qwen2.5-coder-14b","r1-distill-qwen-14b"],"judge":"dolphin3-mistral-24b-q6k"}'
```
Responses include a `redx` object with each step's model, role and seconds.

Measured on a 16-vCPU / 32 GB CPU server (256 max tokens):
| Merge | Example latency |
|---|---|
| router → coder 14B | ~26 s |
| router → general (Mixtral) | ~8 s |
| draft (3B) + refine (24B), short answer | ~11 s |
| draft + refine, code answer | ~44 s |
| panel 8B+14B+14B, 24B judge | ~51 s |
Outside-provider models can be drafters, panel members or judges.
