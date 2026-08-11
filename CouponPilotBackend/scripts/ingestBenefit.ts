import { readFile } from "node:fs/promises";
import { basename } from "node:path";
import { ingestOfficialBenefit, type CalculatorBenefitRule } from "../src/benefitRag.js";

const args = process.argv.slice(2);
const value = (name: string) => {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
};
const file = value("--file");
const title = value("--title");
const provider = value("--provider");
const sourceURL = value("--source-url");
if (!file || !title || !provider || !sourceURL) {
  throw new Error("Usage: npm run ingest:benefit -- --file <official.md> --title <title> --provider <SKT|KT|LG U+> --source-url <https://official-url> [--kind carrier --percent 10 --fixed 0 --max 3000 --min 10000 --combinable true --grades VIP,VVIP --stores 스타벅스 --requires-available true]");
}
const kind = value("--kind");
const commaValues = (name: string) => value(name)?.split(",").map((item) => item.trim()).filter(Boolean);
const rule: CalculatorBenefitRule | undefined = kind === "carrier" ? {
  provider, appliesTo: kind,
  discountPercent: Number(value("--percent") ?? 0) || undefined,
  fixedDiscount: Number(value("--fixed") ?? 0) || undefined,
  maximumDiscount: Number(value("--max") ?? 0) || undefined,
  minimumOrderAmount: Number(value("--min") ?? 0) || undefined,
  combinableWithCoupon: value("--combinable") === "true",
  eligibleGrades: commaValues("--grades"),
  eligibleStoreKeywords: commaValues("--stores"),
  requiresAvailableThisMonth: value("--requires-available") === "true"
} : undefined;
const result = await ingestOfficialBenefit({
  id: basename(file).replace(/\.[^.]+$/, "").replace(/[^a-zA-Z0-9-_]/g, "-"), title, provider, sourceURL,
  content: await readFile(file, "utf8"), rule
});
console.log(JSON.stringify(result));
