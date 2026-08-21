# Official benefit RAG ingestion

Only place text carefully paraphrased from an official carrier, card-company, or bank benefit page in this folder. Keep the official URL, confirmation date, benefit period, membership grade or card conditions, and restrictions in each source document. Never infer a cash value for a voucher-only benefit, points, or an offer whose payment method is unknown. Do not redistribute a full official webpage unless its license expressly permits that use.

## Candidate → approval → active gate

A document is not production evidence merely because it has an embedding. The reviewer must verify all of the following before promotion:

1. The URL is HTTPS and belongs to the named provider's allowlisted official domain.
2. `checkedAt`, `staleAfter`, effective dates, immutable version and reviewer are recorded.
3. Copyright, terms and commercial-use rights have a written decision. `unknown`, `pending`, `미확인` and `검토중` fail closed.
4. A Calculator rule has explicit store keywords, a finite discount in range, and an explicit coupon-combination decision.
5. Card rules also identify the exact product and all required spend, time and remaining-limit conditions.

Retrieval accepts only `active` and non-stale chunks. A corrupt stored rule is rejected again when the index is loaded. The raw text is content-hashed; the immutable version is part of both the object path and chunk ID. Retired documents remain as audit tombstones but are excluded from retrieval and Calculator input immediately.

`ingest:benefit` is a **candidate submission**. It retrieves the official URL again, follows
only allowlisted provider redirects, and saves the raw HTML/PDF response, content type, retrieval
time, final URL, and SHA-256 in the private candidate area alongside the reviewer-authored
structured extraction. It does not create embeddings, update the live index, or affect Calculator
output. Approval re-hashes that exact source object; a missing or altered snapshot fails closed.

Example candidate submission:

```bash
npm run ingest:benefit -- \
  --file docs/benefits/example.md \
  --title "KT 공식 제휴 혜택" \
  --provider "KT" \
  --source-url "https://membership.kt.com/discount/partner/C23/67/PartnerDetail.do" \
  --checked-at 2026-08-20 \
  --stale-after 2026-09-20 \
  --reviewer "박재현" \
  --version "2026-08-20.v1" \
  --license "Official-link citation and factual paraphrase reviewed" \
  --limitations "상품과 월 잔여 횟수는 공식 앱에서 최종 확인" \
  --kind carrier \
  --fixed 2000 \
  --stores "메가박스" \
  --requires-available true \
  --combinable false
```

Use `--kind card --card-product-id <id> --requires-previous-spend true --hours 21,22,23,0` only when the official page provides every condition needed for a deterministic calculation. Omit `--kind` for a source that cannot be priced deterministically (for example, a monthly voucher, points, a first-come promotion, or a benefit requiring an unknown payment method). It can still be approved as an official source, but the calculator will not invent its monetary value.

An operator other than the submitter reviews the snapshot, rule, rights decision and claim span,
then promotes the exact immutable version:

```bash
npm run approve:benefit -- \
  --document-id example \
  --version "2026-08-20.v1" \
  --approved-by "혜택운영자"
```

Approval stores the reviewed text in Cloud Storage, chunks it, creates Vertex AI embeddings, and
atomically updates the live Cloud Storage RAG index. Production rejects self-approval unless
`BENEFIT_ALLOW_SELF_APPROVAL=true` is explicitly configured for a local demo. Calculator fields
are supplied explicitly from the same official document so the LLM never decides a discount
amount. Never upload card numbers, account numbers, CVC values, statements, or transaction history.

## Expiry and emergency withdrawal

When an official benefit ends, contains an error, or its terms change, retire it immediately. The index keeps a tombstone and reason for audit, while retrieval and the Calculator exclude it.

```bash
npm run retire:benefit -- \
  --document-id kt-example-benefit \
  --reason "공식 혜택 종료 및 새 버전 대체" \
  --actor "박재현"
```

Re-ingest a corrected source with a new immutable version. Never overwrite an old source object or manually edit the production index.
