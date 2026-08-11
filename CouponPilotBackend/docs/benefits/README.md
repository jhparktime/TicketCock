# Official benefit RAG ingestion

Only place text copied or carefully paraphrased from an official carrier benefit page in this folder. Keep the original official URL, confirmation date, benefit period, membership grade, and restrictions in each source document. Never infer a cash value for a voucher-only benefit.

Example:

`npm run ingest:benefit -- --file docs/benefits/example.md --title "Example official benefit" --provider "KT" --source-url "https://example.com/benefit" --kind carrier --fixed 2000 --stores "메가박스" --requires-available true --combinable false`

Omit `--kind` for a source that cannot be priced deterministically (for example, a monthly voucher, a first-come promotion, or a benefit requiring an unknown product choice). It will still be retrieved as an official source, but the calculator will not invent its monetary value.

The script stores the original text in Cloud Storage, chunks it, creates Vertex AI embeddings, and updates the Cloud Storage RAG index. Calculator fields are supplied explicitly from the same official document so the LLM never decides a discount amount.
