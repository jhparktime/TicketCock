# CouponCock Tool Call Contract

The LLM is an orchestrator and explanation writer. It has no authority to decide money, mutate a
coupon, or promote an official benefit. Each tool is a narrow, typed, observable contract.

| Sequence | Agent | MCP Tool | Input boundary | Output gate | Authority |
|---|---|---|---|---|---|
| 1 | Store Context | `search_nearby_stores` | Suwon coordinate, 100–1,500m radius, optional store query | Strict coordinate/source/store output schema | Finds candidate stores only |
| 2 | Store Context | `verify_store_with_external_maps` | Store name + 0.01-degree rounded coordinate | Google Maps official MCP; Kakao official REST fallback; citations only | Supplemental place evidence only |
| 3 | Coupon Understanding | none | Confirmed coupon fields only | Privacy guardrail blocks barcode/OCR/PAN/UID | Narrows candidates only |
| 4 | Benefit Retrieval | `retrieve_carrier_benefits` | Carrier, grade, card product name, store name | Active, non-stale official RAG chunks only | Returns evidence and verified rules only |
| 5 | Recommendation | `calculate_best_discount` | Confirmed coupons + verified rules + user price | Input/output Zod schema and deterministic Calculator | **Only authority for final price, saving, ranking** |

## Mandatory controls

1. API → ADK sends an explicit allowlist projection; barcode values, OCR raw text, PAN, CVC,
   e-mail, phone numbers and Firebase UID cannot enter an Agent trace.
2. ADK callback runs before every MCP request and rejects sensitive values, non-Suwon coordinates,
   unsupported carriers, invalid radius/price and over-sized coupon sets.
3. MCP accepts only an internal token plus private Cloud Run service identity. It exposes no public
   browser tool and no mutation tool.
4. Every Tool has a strict Zod input schema **and its result is parsed again** against the declared
   output schema before the Agent receives it.
5. RAG may provide a Calculator rule only when it is active, non-stale, rights-reviewed and linked
   to an official source. Otherwise it is citation-only evidence.
6. ADK runs in `shadow` mode first. The API compares the Agent's returned savings/final price with
   the Calculator and rejects disagreement. `explanation` mode never replaces Calculator output.
7. All Tool calls receive correlation IDs, latency/error traces and per-user endpoint quotas.
8. Any failed Tool, DLP or Model Armor check is fail-closed for that AI branch; coupon-only
   Calculator output or explicit "official confirmation required" is used instead.
9. External maps never receive raw device GPS: the internal MCP rounds it to a 0.01-degree grid
   and drops external prose, returning only source status and attribution URLs. Google Maps MCP is
   primary; Kakao Local is a disabled-until-key fallback, not a community MCP dependency.

## Human authority boundary

- User confirms OCR coupon fields, card-product candidates, recommended payment choice, and the
  post-payment “used” record.
- A second operator approves an official-benefit source snapshot before it becomes searchable.
- No Agent or Tool can mark a coupon used, save a payment card, or promote benefit data.
