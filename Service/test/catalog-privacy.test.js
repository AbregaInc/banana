// The privacy manifest declares every kind of data the catalog sends to the service
// (docs/design/DATA-PLATFORM.md §5 and §10). A new type in Shared/DataCatalog.json fails here
// until a rule below says which App Privacy categories it falls under, and then until
// Banana/PrivacyInfo.xcprivacy and tools/app-store/app-privacy.md declare them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const root = new URL("../../", import.meta.url);
const catalog = JSON.parse(readFileSync(new URL("Shared/DataCatalog.json", root), "utf8"));
const manifestText = readFileSync(new URL("Banana/PrivacyInfo.xcprivacy", root), "utf8");
const checklist = readFileSync(new URL("tools/app-store/app-privacy.md", root), "utf8");

// Which App Privacy categories each type needs. Every type must match at least one rule; a type
// can match several. `blob` narrows a rule to a type that carries that blob field.
const RULES = [
  { match: /^podcast\.(listen|progress)$/, needs: ["ProductInteraction"], why: "listening history and playback progress sync for app functionality" },
  { match: /^plan\.bookingType$/, needs: ["PhoneNumber", "PhysicalAddress"], why: "optional host number and in-person address in booking settings" },
  { match: /^health\./, needs: ["Health"], why: "health tier: Apple Health data and what it covers" },
  { match: /^health\.(snapshot|workout)/, needs: ["Fitness"], why: "workouts, their samples and plans" },
  { match: /^health\.workout$/, needs: ["PreciseLocation"], why: "a workout's route is in its samples" },
  { match: /^food\./, needs: ["Health"], why: "meals, supplements, medication and doses" },
  { match: /^food\.mealPhoto$/, blob: "v", needs: ["PhotosorVideos"], why: "meal photos" },
  { match: /^food\.searchPick$/, needs: ["SearchHistory"], why: "the words searched for a food" },
  { match: /^notes\.voiceNote$/, blob: "audio", needs: ["AudioData", "OtherUserContent"], why: "a note's recording and its text" },
  { match: /^podcast\.listen$/, blob: "route", needs: ["PreciseLocation"], why: "where an episode was listened to" },
  { match: /^podcast\./, needs: ["OtherUserContent"], why: "shows, progress, listening, transcripts" },
  { match: /^plan\./, needs: ["OtherUserContent"], why: "routines, alarms, a day's changes, reminders' timing" },
  { match: /^core\.guestPick$/, needs: ["Contacts"], why: "names typed and the other person's address chosen" },
  { match: /^core\.smartSettings$/, needs: ["PreciseLocation", "OtherDataTypes"], why: "settings, with saved places' coordinates" },
  { match: /^core\.wakePlan$/, needs: ["Health", "OtherUserContent"], why: "the wake and bed times worked out on the phone, from sleep and recovery" },
  { match: /^core\.(appSettings|modules|hubStatus|hubRequest)$/, needs: ["OtherDataTypes"], why: "settings and device status" },
];

// The names App Store Connect shows, which the checklist must use.
const CONNECT_NAMES = {
  Name: "Name", PhoneNumber: "Phone Number", PhysicalAddress: "Physical Address",
  EmailAddress: "Email Address", UserID: "User ID", DeviceID: "Device ID",
  ProductInteraction: "Product Interaction", OtherDiagnosticData: "Other Diagnostic Data",
  OtherDataTypes: "Other Data Types", OtherUserContent: "Other User Content",
  CrashData: "Crash Data", PerformanceData: "Performance Data", Health: "Health",
  Fitness: "Fitness", PreciseLocation: "Precise Location", PhotosorVideos: "Photos or Videos",
  AudioData: "Audio Data", Contacts: "Contacts", SearchHistory: "Search History",
};

/** The manifest's collected types: {Health: {linked, tracking, purposes}, ...}. */
function declared(text) {
  const section = text.split("<key>NSPrivacyCollectedDataTypes</key>")[1].split("<key>NSPrivacyAccessedAPITypes</key>")[0];
  const out = {};
  for (const dict of section.split("<dict>").slice(1)) {
    const type = dict.match(/<string>NSPrivacyCollectedDataType(\w+)<\/string>/)?.[1];
    if (!type) continue;
    assert.ok(!out[type], `${type} is declared twice`);
    out[type] = {
      linked: /NSPrivacyCollectedDataTypeLinked<\/key>\s*<true\/>/.test(dict),
      tracking: /NSPrivacyCollectedDataTypeTracking<\/key>\s*<true\/>/.test(dict),
      purposes: [...dict.matchAll(/NSPrivacyCollectedDataTypePurpose(\w+)/g)].map((m) => m[1]),
    };
  }
  return out;
}

function needed(entry) {
  return RULES.filter((r) => r.match.test(entry.type) && (!r.blob || entry.blobs?.[r.blob]));
}

test("every catalog type is claimed by a privacy rule", () => {
  const unclaimed = catalog.types.filter((t) => needed(t).length === 0).map((t) => t.type);
  assert.deepEqual(unclaimed, [], "add a rule to RULES saying which App Privacy categories these fall under");
});

test("rules with a blob still find it in the catalog", () => {
  for (const rule of RULES.filter((r) => r.blob)) {
    const hits = catalog.types.filter((t) => rule.match.test(t.type));
    assert.ok(hits.length > 0, `${rule.match} matches no catalog type`);
    for (const t of hits) assert.ok(t.blobs?.[rule.blob], `${t.type} no longer has the blob field ${rule.blob}`);
  }
});

test("health-tier types are declared as Health or Fitness", () => {
  for (const t of catalog.types.filter((t) => t.tier === "T2")) {
    const cats = needed(t).flatMap((r) => r.needs);
    assert.ok(cats.includes("Health") || cats.includes("Fitness"), `${t.type} is T2 but not Health or Fitness`);
  }
});

test("the manifest declares every category the catalog needs, linked, for app functionality, never tracking", () => {
  const have = declared(manifestText);
  for (const t of catalog.types) {
    for (const rule of needed(t)) {
      for (const cat of rule.needs) {
        const d = have[cat];
        assert.ok(d, `${t.type} (${rule.why}) needs NSPrivacyCollectedDataType${cat} in Banana/PrivacyInfo.xcprivacy`);
        assert.equal(d.linked, true, `${cat} must be linked: it is kept in the person's space`);
        assert.equal(d.tracking, false, `${cat} is never used for tracking`);
        assert.ok(d.purposes.includes("AppFunctionality"), `${cat} needs the App Functionality purpose`);
      }
    }
  }
  assert.equal(/<key>NSPrivacyTracking<\/key>\s*<false\/>/.test(manifestText), true);
});

test("the App Store Connect checklist names every declared category", () => {
  for (const type of Object.keys(declared(manifestText))) {
    const name = CONNECT_NAMES[type];
    assert.ok(name, `add ${type}'s App Store Connect name to CONNECT_NAMES`);
    assert.ok(checklist.includes(`**${name}**`), `tools/app-store/app-privacy.md has no **${name}** entry`);
  }
});

// Account identity reaches the service outside the sync catalogue. Google profile names
// are retained by signInAs, including identity-token sign-in from the native app.
test("account identity collection is declared as linked app functionality", () => {
  const have = declared(manifestText);
  for (const type of ["Name", "EmailAddress", "UserID", "DeviceID"]) {
    assert.ok(have[type], `account identity needs NSPrivacyCollectedDataType${type}`);
    assert.equal(have[type].linked, true);
    assert.equal(have[type].tracking, false);
    assert.ok(have[type].purposes.includes("AppFunctionality"));
  }
});
