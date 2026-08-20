import { approveOfficialBenefitCandidate } from "../src/benefitRag.js";

const value = (name: string) => {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
};

const documentId = value("--document-id");
const version = value("--version");
const approvedBy = value("--approved-by");

if (!documentId || !version || !approvedBy) {
  throw new Error("Usage: npm run approve:benefit -- --document-id <id> --version <immutable-version> --approved-by <reviewer>");
}

console.log(JSON.stringify(await approveOfficialBenefitCandidate(documentId, version, approvedBy)));
