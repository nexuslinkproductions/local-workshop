# 58c — Decoding, sampling and structured output for the Chief 9B (Ornith-1.5-9B / Qwen3.5-family)

Status: research only. Read-only pass. No GPU, no llama-server started, no config edited.
Scope: server-side decoding settings that change agent reliability for the Qwen3.5-family 9B that runs
Chief (`ornith-chief`): vendor sampling, what our llama-swap entry sends today, `--jinja` tool-call
parsing, grammar/JSON-schema constrained decoding, thinking budget, and per-request overrides.
Engine: `LOCAL-AI-LAB/engines/llama.cpp-sycl-tip` at `358a420ec` (2026-10-12 23:00).
Config: `LOCAL-AI-LAB/serve/config.yaml` (v264), launch `LOCAL-AI-LAB/serve/bakeoff-launch.sh`.

---

## 1. Verdict (read this first)

1. **Greedy (`--temp 0`) is the wrong default for this family.** The GGUF vendor measured greedy at a
   37.5% degeneration rate vs 4.7% for the recommended sampler (Ornith-recommended), i.e. **low
   temperature makes looping worse here, the opposite of the usual advice**. Our entry sends `--temp 0`.
2. **`--repeat-penalty 1.05` is the wrong knob.** The vendor's recommended set uses
   `repetition_penalty=1.0` (i.e. OFF) and `presence_penalty=1.5` (additive) instead. A weak
   multiplicative repeat penalty over the last 64 tokens is not what they measured and can distort
   repeated argument tokens inside tool calls.
3. **Tool-call *format* is already grammar-constrained**, so greedy does not corrupt the XML shape.
   What greedy/repeat-penalty hurt is call *selection, argument values, and long-generation stability*
   (the eval's read/invoice failures are long-answer failures, exactly where the vendor's greedy
   measurement bites).
4. **Our GGUF's embedded template triggers llama.cpp's specialized Qwen3-Coder/Qwen3.5 parser**
   (`common/chat.cpp:1219`), which handles "text before `<tool_call>`" and tool calls that start inside
   ` thinking`. That sidesteps the open upstream bug class (#20260 / #21158) that hits the generic
   autoparser path. Keep `--jinja`.
5. **Do not add a GBNF grammar for tool calls** — the server builds one automatically. Use
   `response_format`/`json_schema` only to force *structured answers* (e.g. the invoice/read tasks).

---

## 2. Vendor-recommended sampling (measured by vendor, quoted)

### Ornith-1.5-9B (the model we run)

From the Ornith model card (`https://huggingface.co/ornith-ai/Ornith-1.5-9B`, accessed 2026-10-13):
- **General tasks:** `temperature=1.0, top_p=0.95, top_k=20, min_p=0.0, presence_penalty=1.5, repetition_penalty=1.0`
- **Precise coding:** `temperature=0.6, top_p=0.95, top_k=20, min_p=0.0, presence_penalty=0.0, repetition_penalty=1.0`

The card also states Ornith-1.5-9B **is a reasoning model**: the assistant turn opens with a
` thinking … </think>` block by default, tool calls are `<tool_call>` XML, and the serving recipes use a
`qwen3_xml` (vLLM) / `qwen3_coder` (SGLang) tool-call parser plus a `qwen3` reasoning parser.
Ornith-1.5-9B is a dense Qwen3.5-9B-architecture hybrid (linear + full attention) VL fine-tune.

### The measured greedy-vs-recommended table (protoLabs GGUF card)

`https://huggingface.co/protoLabsAI/Ornith-1.5-9B-MTP-GGUF` (accessed 2026-10-13), measured on `IQ2_M`,
64 samples per arm (8 prompts x 8 seeds, 1500-token generations):

| sampling | degenerate | rate |
|---|---|---|
| Ornith-recommended (`temp 1.0 … presence_penalty 1.5`) | 3 / 64 | **4.7%** |
| llama.cpp defaults (`temp 0.8, top_k 40, top_p 0.95, min_p 0.05, presence 0`) | 18 / 64 | 28.1% |
| greedy (`temp 0`) | 24 / 64 | **37.5%** |

Quote: "**Low temperature makes looping worse on this family** — the opposite of the usual advice."
Fisher two-sided p = 5.5e-4 vs defaults.

Rung note (same card): the wider sweep split by quant — **every rung from `IQ4_XS` up: 0 failures out
of 234; `Q4_K_M` never degenerated once.** We run `Q4_K_M`, so the *repetition* failure mode is
lower-risk on our quant, but the card is explicit that **"the sampler flags are NOT optional"** and
llama.cpp's defaults "apply no repetition control and measurably increase looping."

Second failure mode the card documents, **not fixable by sampling**: on hard code the model argues
with itself until the token budget is exhausted (reproduced at 32,768 tokens with thinking OFF,
repetition score near zero). "this family is strong at tool calling and weak at code."

### Qwen3.5-9B (the base architecture; same recommended sampler)

`https://huggingface.co/Qwen/Qwen3.5-9B` (accessed 2026-10-13), Best Practices:
- **Thinking, general:** `temperature=1.0, top_p=0.95, top_k=20, min_p=0.0, presence_penalty=1.5, repetition_penalty=1.0`
- **Thinking, precise coding:** `temperature=0.6, top_p=0.95, top_k=20, min_p=0.0, presence_penalty=0.0, repetition_penalty=1.0`
- **Instruct (non-thinking), general:** `temperature=0.7, top_p=0.8, top_k=20, min_p=0.0, presence_penalty=1.5, repetition_penalty=1.0`
- **Instruct (non-thinking), reasoning:** `temperature=1.0, top_p=1.0, top_k=40, min_p=0.0, presence_penalty=2.0, repetition_penalty=1.0`

Also: adjust `presence_penalty` between 0 and 2 to reduce endless repetitions (higher can cause
language mixing); recommend output length 32,768 for most queries; **no thinking content in history**
(the Jinja template already strips it). Qwen3.5 operates in thinking mode by default.

### Qwen3.6

The task asked to check 3.6 too. The Ornith card's benchmark table lists Qwen3.6-35B-A3B as a sibling;
our shelf's `qwen3.6-35b-a3b-mtp` entry also sends `--temp 0 --repeat-penalty 1.05`. The Qwen3.5
recommended sets above are the same family recipe and are what the community cards for Qwen3.6 quants
repost verbatim (e.g. `TheCluster/Qwen3.5-35B-A3B-Heretic-MLX-9bit` README, accessed 2026-10-13).
Vendor-claim confidence on 3.6-specific numbers is lower (I did not find a 3.6 card with its own
table); treat the 3.5 set as the starting point for 3.6 and re-measure.

**llama.cpp build defaults** (source of truth, this build): `common/common.h:233-245`
`top_k=40, top_p=0.95, min_p=0.05, temp=0.80, penalty_repeat=1.00, penalty_present=0.00, penalty_last_n=64`.

---

## 3. What our llama-swap entry sends today

`serve/bakeoff-launch.sh:19` (the last line, the one `ornith-chief` runs):

```
--jinja --temp 0 --repeat-penalty 1.05 "${XTRA[@]}"
```

`ornith-chief` = `bakeoff-launch.sh ${PORT} 262144 <gguf> <mmproj> q4_0 --mmproj-cpu` with
`BAKEOFF_EXTRA="-ub 256 -b 256"` (`serve/config.yaml:152-168`).

So every request gets **greedy decoding + a 1.05 multiplicative repeat penalty over the last 64
tokens**, unless the client body overrides it. Three problems:

1. `--temp 0` is the exact setting the vendor measured as the *worst* of the three arms (37.5%).
2. `--repeat-penalty 1.05` is a weaker/different mechanism than the vendor's `presence_penalty 1.5`,
   and the vendor wants `repetition_penalty=1.0` (off). A multiplicative penalty penalises *every*
   token in the last 64 that has appeared before, including legitimately repeated argument tokens
   (repeated JSON keys, the same path segment, digits) — it can mangle tool-call arguments.
3. Greedy also removes the sampling diversity the vendor's RL tuning assumes, and is a plausible
   contributor to the eval's read/invoice failures (long answers, exact-number extraction).

Note: the same two flags are on every other `config.yaml` entry (gemma4 uses a different script;
`qwen3.6-35b-a3b-mtp`, `minicpm-v-4.7-35b-a3b`, `ui-venus-1.5-30b-a3b`, `qwen3.8-flash-next` each
hard-code `--temp 0 --repeat-penalty 1.05` in their own `cmd`). Fixing this entry does not fix those.

---

## 4. Exact changes

### 4a. `serve/bakeoff-launch.sh` — replace line 19

The launch default should be the vendor's **instruct** set (Chief runs thinking OFF by default), not
greedy. This also fixes `ornith-9b` and `ministral3-14b` (same script).

Replace:
```
    --jinja --temp 0 --repeat-penalty 1.05 "${XTRA[@]}"   # BAKEOFF_EXTRA last so its flags override
```
with:
```
    --jinja --temp 0.7 --top-p 0.8 --top-k 20 --min-p 0.0 --presence-penalty 1.5 --repeat-penalty 1.0 "${XTRA[@]}"   # Qwen3.5-family instruct sampler (config.yaml setParamsByID overrides per id); BAKEOFF_EXTRA last so its flags override
```

Expected effect: removes greedy looping on long generations (read/invoice/nav categories); leaves
tool-call format unchanged (grammar handles that).

### 4b. `serve/config.yaml` — per-id sampling for `ornith-chief`

`setParamsByID` is applied to the request body *after* `setParams`, and request-body sampling params
override the server's CLI defaults (confirmed below), so this is the per-alias lever. Replace the
`ornith-chief` filter block (`serve/config.yaml:164-167`) with:

```yaml
    filters:
      setParamsByID:
        # Instruct (non-thinking) general — Qwen3.5 card (2026-02) / Ornith card
        ornith-chief:
          chat_template_kwargs: { enable_thinking: false }
          temperature: 0.7
          top_p: 0.8
          top_k: 20
          min_p: 0.0
          presence_penalty: 1.5
          repeat_penalty: 1.0
        # Thinking general — Qwen3.5 card; budget stays 512 (research/26 r26b2 / research/56)
        ornith-chief-think:
          chat_template_kwargs: { enable_thinking: true }
          thinking_budget_tokens: 512
          temperature: 1.0
          top_p: 0.95
          top_k: 20
          min_p: 0.0
          presence_penalty: 1.5
          repeat_penalty: 1.0
```

Expected effect: instruct alias gets the vendor's non-thinking general set; thinking alias gets the
thinking general set. `repeat_penalty: 1.0` explicitly neutralises the CLI `--repeat-penalty` default.

Optional (same idea, different numbers) for the `ornith-9b` bakeoff id at `serve/config.yaml:144-147`:
add `temperature: 0.7, top_p: 0.8, top_k: 20, min_p: 0.0, presence_penalty: 1.5, repeat_penalty: 1.0`.

Validate without loading a model:
```
~/.local/bin/llama-swap --config serve/config.yaml -validate     # expect: config is valid, N model(s)
```

### 4c. Why this works (mechanism, verified in source)

- llama-swap applies `setParamsByID` via `sjson` after `setParams`; keys support `${MODEL_ID}`, values
  may be objects; protected keys (`model`) cannot be set. Source:
  `mostlygeek/llama-swap` `internal/server/filters.go`, `proxy/config/filters.go` (accessed 2026-10-13).
- The upstream server copies **any** unrecognised request-body key into `llama_params`
  (`tools/server/server-common.cpp:1470-1474`) and applies them to slot sampling in
  `launch_slot_with_task()`; the recognised keys include `temperature, top_p, top_k, min_p,
  repeat_penalty, presence_penalty, repeat_last_n, frequency_penalty, seed, dynatemp_*, xtc_*,
  typical_p, dry_*` (`tools/server/server-task.cpp:44-121`). So a body `temperature` overrides the
  CLI `--temp`.

---

## 5. llama.cpp tool-call parsing with `--jinja` for qwen35

### How our template is routed

`Ornith-1.5-9B-Q4_K_M.gguf` embeds `general.architecture = qwen35` and a chat template containing
`<tool_call>`, `<function=`, `<parameter=` (extracted with `strings` on the GGUF, 2026-10-13). That
triple matches the specialized detector at `common/chat.cpp:1219-1227`:

```cpp
// Qwen3-Coder XML tool calls, also used by Nemotron Nano 3, Qwen3.5 and StepFun-3.5-Flash
if (src.find("<tool_call>") != npos && src.find("<function=") != npos &&
    src.find("<parameter=") != npos && <no-newline exclusion does not match>) {
    return common_chat_params_init_qwen3_coder;   // common/parsers/qwen3-coder.cpp
}
```

The exclusion is for templates that write `'<tool_call><function=' ~ tool_call.name ~ '>'` (no
newline). Our template uses newlines between the tags, so the exclusion does **not** fire and we get
the specialized parser, not the generic autoparser. This matters (see bugs below).

### What the specialized parser gives us (`common/parsers/qwen3-coder.cpp`)

- **Text before `<tool_call>` is handled.** The root rule is
  `generation_prompt + (reasoning << p.content(p.until_one_of(tool_call_starts)) << tool_calls)`
  (`qwen3-coder.cpp:169-170`). Content (including prose) is consumed up to the first tool-call start.
  Our template explicitly permits this: "You may provide optional reasoning for your function call in
  natural language BEFORE the function call" (template text, quoted from the GGUF).
- **Tool calls inside thinking are handled.** `thinking_end_tags = { "\n</think>", "</think>",
  "<tool_call>" }` (`qwen3-coder.cpp:28`) — `<tool_call>` is treated as an end-of-reasoning tag, so a
  call emitted right after/inside the think block is parsed instead of swallowed.
- **Arguments are grammar-constrained.** For each tool, required args are accepted in any order
  (`p.permute`, `qwen3-coder.cpp:144`) and typed by schema (`string`/`object`/`array`/`number`/`bool`
  branches, lines 111-135).
- **Parallel tool calls are supported.** `inputs.parallel_tool_calls ? tool_call_first +
  p.zero_or_more(tool_call) : tool_call_first` (`qwen3-coder.cpp:166`). Default comes from the
  template caps (`server-common.cpp:1369`, `parallel_tool_calls` README:1356).
- **Lazy grammar triggers.** When tools are present and `tool_choice=auto`, the server builds a
  *lazy* grammar with word triggers `<tool_call>` and `<function=NAME>` (`qwen3-coder.cpp:177-188`).
  This is why tool-call format is already guaranteed and why a hand-written GBNF for tools is
  redundant.

### Known bugs (upstream) and whether they apply to us

| bug | what it is | applies to us? |
|---|---|---|
| ggml-org/llama.cpp #21158 (build 8576) and #20260 (OPEN) | peg-native / autoparser path returns `Failed to parse input at pos N` when the model emits text before `<tool_call>` | **Low risk.** Those hit the generic autoparser. Our template routes to the specialized `qwen3_coder` parser, which consumes pre-call text by design. Our build (`358a420ec`, 2026-10-12) is far newer than build 8576. Verify with test T2. |
| ggml-org/llama.cpp #21771 | `p.json()` fails on `array<object>` parameter values in the `TAG_WITH_TAGGED` format; a partial `tool_calls[].function.arguments = "{"` delta poisons multi-turn history | Format-specific (TAG_WITH_TAGGED), not the qwen3_coder XML path. Risk only if we add an `array<object>` tool parameter. Keep tool schemas to flat string/number/boolean params where possible. |
| ikawrakow/ik_llama.cpp #1613 | streaming tool-calling degenerates into hundreds of repeated `<tool_call>` blocks | **ik_llama.cpp, not mainline.** We run mainline-derived `llama.cpp-sycl-tip`. Still, this is the failure greedy + a weak repeat penalty can encourage; fixed sampler reduces it. |
| community: `barubary/qwen3.5-barubary-attuned-chat-template` | drop-in template fixing "20+ bugs" in the official Qwen3.5 template (argument mapping, parallel-call separation, truncation, auto-disable thinking when tools active) | Reference only. The URL 404'd on extract (2026-10-13). If we ever see raw XML leaking or empty args, this is the template to test via `--chat-template-file`. |
| community reports (r/LocalLLaMA, 2026) | Qwen3.5 emits tool calls *inside* ` thinking` blocks; some servers won't parse them | **Handled** by `thinking_end_tags` including `<tool_call>` (above). Thinking OFF for `ornith-chief` sidesteps it anyway. |

### Chat-template overrides

- `--chat-template-file <file>` and `--chat-template <inline>` let you replace the embedded template
  without re-quantising; `chat_template_kwargs` (per request) drives the template variables
  (`enable_thinking`, `reasoning_effort`). README:1348, 1350.
- We already use `chat_template_kwargs.enable_thinking` per id. No override needed today.

---

## 6. Grammar / JSON-schema constrained decoding

Three levers, all on the OpenAI chat endpoint (`tools/server/server-common.cpp:1300-1324`):

1. **`response_format: {"type":"json_object"}`** → any JSON object.
2. **`response_format: {"type":"json_schema", "json_schema":{"name":..., "schema":{...}}}`** (or the
   flat `{"type":"json_object","schema":{...}}`) → schema-constrained JSON.
3. **`json_schema: {...}`** (llama.cpp-native field) and **`grammar: "<GBNF>"`** (raw GBNF).
   `json_schema` and `grammar` are mutually exclusive (throws otherwise, line 1302).

Where this helps Chief:
- **read / invoice categories** (the weakest: read 3/8, invoice 2/6). Force a fixed JSON envelope for
  answers that must carry exact numbers, e.g. `{"hostname":string,"os":string,"version":string}` or
  the invoice's `{"net":number,"vat":number,"gross":number,"kleinunternehmer":boolean}`. The grammar
  guarantees the field exists and is a number/boolean, so the model can't drift into prose and the
  eval's "exact number" check becomes a parse, not a regex over prose.
- **Do NOT wrap tool calls in a JSON grammar.** With tools + `--jinja`, the server already applies the
  lazy XML grammar (section 5). Adding `response_format` alongside tools is allowed
  (`include_grammar = has_response_format || (has_tools && tool_choice != none)`,
  `qwen3-coder.cpp:43`) but it changes the parser branch to the response-format branch
  (`qwen3-coder.cpp:85-87`) and drops the tool-call branch — do not combine them in one request.

Ceiling to note: schema-constrained JSON forces *shape*, not *correctness*. It will not fix a wrong
number; it only makes the wrong number machine-checkable.

---

## 7. Thinking budget tuning

Mechanism (`common/reasoning-budget.cpp`, `tools/server/server-common.cpp:1439-1454`):
- Request keys `thinking_budget_tokens` or `reasoning_budget_tokens` (and CLI `--reasoning-budget`,
  `--reasoning-budget-message`). Falls back to the server option if the body omits it.
- The sampler counts tokens inside the thinking block; when the budget is exhausted it **forces the
  end sequence** (`</think>`) by setting all logits to -inf except the forced token
  (`reasoning-budget.cpp:166-186`). It **re-arms on a new ` thinking`** (multiple think blocks each get
  a fresh window, line 155-166).
- Only armed when the session has thinking end tags (`server-common.cpp:1447`), which the qwen3_coder
  parser provides for our template.

Our config uses `thinking_budget_tokens: 512` for `ornith-chief-think` (from research/26 r26b2: 512
answered both probe puzzles, 256 failed both). The Ornith GGUF template only references
`enable_thinking` (no budget kwarg — confirmed by `strings` on the GGUF), so the budget is a
**sampler-side** early stop, independent of the template. That is the correct and only knob for a
template that lacks a budget variable.

Tuning guidance:
- Keep 512 for `ornith-chief-think`. If thinking-mode answers get truncated mid-reasoning, raise to
  1024 and re-run T4; if latency matters more, try 384.
- For `ornith-chief` (thinking off) no budget applies; thinking is disabled at the template.
- `reasoning_effort` is passed to the template only if the template reads it (`server-common.cpp:1421-1427`);
  Ornith's template does not, so `reasoning_effort` is inert here. Use `thinking_budget_tokens`.

---

## 8. Per-request overrides via llama-swap `setParamsByID`

- Semantics (`mostlygeek/llama-swap` `proxy/config/filters.go`): `setParams` sets defaults for the
  model; `setParamsByID` maps the *requested* id (or alias) to params and is applied **after**
  `setParams`, so it can override them. Keys support `${MODEL_ID}` substitution; values may be
  strings/numbers/booleans/arrays/objects; `model` is protected. A newer `?` key suffix means
  "set only if undefined" (filters commit #1075).
- This is how one loaded model (same process, same weights) behaves differently per alias. We already
  use it for `enable_thinking`; section 4b extends it to sampling.
- Because the injected keys land in the request body, they hit the server as ordinary OpenAI params
  and override the CLI defaults (section 4c). Protected/inert keys: `model` cannot be set; the server
  ignores unknown keys silently (copied to `llama_params` but no sampler matches them).

---

## 9. One-run tests (to run when the GPU is free — NOT run by this research agent)

All assume llama-swap on `127.0.0.1:18080`. Run under `flock -x bench/.gpu.lock` per lab rules.

**T1 — setParamsByID actually overrides the CLI `--temp 0` (proves 4b).**
`verbose:true` returns `__verbose.generation_settings` with the applied sampler
(`tools/server/server-task.cpp:332-397`).
```sh
curl -s http://127.0.0.1:18080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model":"ornith-chief","messages":[{"role":"user","content":"hi"}],"max_tokens":8,"verbose":true
}' | jq '.__verbose.generation_settings | {temperature,top_p,top_k,min_p,presence_penalty,repeat_penalty}'
```
Pass: `temperature:0.7, top_p:0.8, top_k:20, min_p:0, presence_penalty:1.5, repeat_penalty:1`.
(Fail = you still see `temperature:0` from the CLI flag.)

**T2 — tool call with prose before the tag (proves section 5 bug is not hitting us).**
```sh
curl -s http://127.0.0.1:18080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model":"ornith-chief",
  "messages":[{"role":"user","content":"Think about it, then read /etc/hostname and report the hostname."}],
  "tools":[{"type":"function","function":{"name":"read_file","description":"read a file",
    "parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}],
  "max_tokens":256
}' | jq -r '.choices[0].message | {finish:null, tc:.tool_calls}'
```
Pass: exactly one `tool_calls` entry, `name=read_file`, `arguments` a valid JSON object with `path`
(a prefix of prose in `content` is fine). Fail = `finish_reason` stop with raw `<tool_call>` XML in
`content`, or a 500 `Failed to parse input at pos`.

**T3 — schema-constrained structured answer (proves section 6).**
```sh
curl -s http://127.0.0.1:18080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model":"ornith-chief",
  "messages":[{"role":"user","content":"Report the hostname and OS of this machine."}],
  "response_format":{"type":"json_schema","json_schema":{"name":"ans","schema":{
    "type":"object","properties":{"hostname":{"type":"string"},"os":{"type":"string"}},
    "required":["hostname","os"]}}},
  "max_tokens":128
}' | jq -r '.choices[0].message.content' | jq .
```
Pass: parses as JSON with both keys, string values. This is the shape to apply to the read/invoice
eval tasks.

**T4 — thinking budget is enforced (proves section 7).**
```sh
curl -s http://127.0.0.1:18080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model":"ornith-chief-think","messages":[{"role":"user","content":"What is 17*23?"}],
  "max_tokens":2048,"thinking_budget_tokens":64
}' | jq -r '.choices[0].message.reasoning_content | length'
```
Pass: bounded (roughly <= ~100 chars of reasoning); `content` still has the answer. Compare against
`thinking_budget_tokens:512` in the same shape — the 64 arm's reasoning must be materially shorter.

**T5 — greedy-vs-recommended degeneration A/B (the vendor's measurement, on our quant).**
```sh
for i in $(seq 1 8); do
  curl -s http://127.0.0.1:18080/v1/chat/completions -H 'Content-Type: application/json' -d '{
    "model":"ornith-chief","seed":'"$i"',"max_tokens":1500,
    "messages":[{"role":"user","content":"Write a 1200-word essay on the history of the bicycle."}]
  }' | jq -r '.choices[0].message.content' >> /tmp/ornith-sampler.out
done
```
Pass criterion: no arm degenerates (repeated n-gram runs). Run once with the new sampler (T1 config)
and once with `"temperature":0,"repeat_penalty":1.05` injected to reproduce the greedy arm. On
`Q4_K_M` the vendor saw 0/64 failures, so a null result here is expected and does not refute the
recommendation — it just means our quant is safe; the sampler still removes the *risk*.

---

## 10. Open items / things I could not verify read-only

1. **Exact 3.6 card numbers.** No Qwen3.6 card with its own sampling table was found; the 3.5 recipe
   is the working assumption for `qwen3.6-35b-a3b-mtp` (which also sends greedy today).
2. **The other shelf entries** (`qwen3.6-35b-a3b-mtp`, `minicpm-v-4.7`, `ui-venus-1.5`,
   `qwen3.8-flash-next`) each hard-code `--temp 0 --repeat-penalty 1.05` in their `cmd`. Out of scope
   here but the same argument applies; each needs its own card check.
3. **Whether `--temp 0` measurably costs eval points** is not yet measured for Chief. The vendor's
   table is prose/code, not agent tool loops. T5 is the cheapest first probe; the real answer is a
   bakeoff42 re-run with the new sampler vs the old.
4. **`presence_penalty 1.5` can cause language mixing** per the Qwen card (higher values). Chief is
   British-English; watch for stray non-English tokens in the read/web categories after the change.

### Sources (all accessed 2026-10-13)
- `https://huggingface.co/ornith-ai/Ornith-1.5-9B` — Ornith card, sampler, reasoning/tool parser notes.
- `https://huggingface.co/protoLabsAI/Ornith-1.5-9B-MTP-GGUF` — measured greedy/defaults/recommended table, rung sweep, second failure mode.
- `https://huggingface.co/Qwen/Qwen3.5-9B` — Best Practices sampling sets, thinking default, output length.
- `https://github.com/ggml-org/llama.cpp/issues/21158`, `/issues/20260`, `/issues/21771` — tool-parse bugs.
- `https://github.com/ikawrakow/ik_llama.cpp/issues/1613` — ik_llama.cpp repeated-tool-call loop.
- `https://github.com/mostlygeek/llama-swap` `proxy/config/filters.go`, `internal/server/filters.go` — setParamsByID semantics.
- Local source: `engines/llama.cpp-sycl-tip/{common/chat.cpp, common/parsers/qwen3-coder.cpp, common/reasoning-budget.cpp, tools/server/server-common.cpp, tools/server/server-task.cpp, tools/server/README.md, common/common.h}`.
