import assert from "node:assert/strict";
import {
  checkModelArmorText,
  configuredDlpMode,
  configuredModelArmorMode,
  deidentifyTextForModel,
  dlpDeidentifyPayload
} from "../src/cloudSafety.js";

const original = {
  dlpMode: process.env.DLP_MODE,
  armorMode: process.env.MODEL_ARMOR_MODE
};

try {
  process.env.DLP_MODE = "monitor";
  process.env.MODEL_ARMOR_MODE = "enforce";
  assert.equal(configuredDlpMode(), "monitor");
  assert.equal(configuredModelArmorMode(), "enforce");

  const payload = dlpDeidentifyPayload("contact test@example.com or 010-1234-5678");
  assert.deepEqual(payload.inspectConfig.infoTypes.map(({ name }) => name), [
    "EMAIL_ADDRESS",
    "PHONE_NUMBER",
    "CREDIT_CARD_NUMBER"
  ]);
  assert.equal(payload.inspectConfig.includeQuote, false);

  process.env.DLP_MODE = "off";
  const locallySafe = await deidentifyTextForModel("email user@example.com");
  assert.equal(locallySafe.status, "disabled");
  assert.doesNotMatch(locallySafe.text, /user@example\.com/);

  process.env.MODEL_ARMOR_MODE = "off";
  assert.equal(await checkModelArmorText("coupon safety test", "prompt"), "disabled");
  console.log("Cloud safety configuration tests passed");
} finally {
  if (original.dlpMode === undefined) delete process.env.DLP_MODE;
  else process.env.DLP_MODE = original.dlpMode;
  if (original.armorMode === undefined) delete process.env.MODEL_ARMOR_MODE;
  else process.env.MODEL_ARMOR_MODE = original.armorMode;
}
