import { retireOfficialBenefit } from "../src/benefitRag.js";

const value = (name: string) => {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
};

const documentId = value("--document-id");
const reason = value("--reason");
const actor = value("--actor");
if (!documentId || !reason || !actor) {
  throw new Error("Usage: npm run retire:benefit -- --document-id <id> --reason <reason> --actor <reviewer>");
}

console.log(JSON.stringify(await retireOfficialBenefit(documentId, reason, actor)));
