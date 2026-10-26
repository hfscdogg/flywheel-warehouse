/**
 * Gmail → vendor drop bucket.
 *
 * Security Central emails the monthly dealer statement on the 25th
 * ("Statement EMail", from Security Central Accounting, one PDF attached).
 * This copies that attachment into gs://<bucket>/securitycentral/statement/
 * so the ingest-vendordrop workflow lands it the next morning — the same
 * path a browser upload takes, with nobody doing the upload.
 *
 * It runs as the Google Workspace user it is installed under, with that
 * user's own permissions: Gmail read + modify (to label what was copied) and
 * Cloud Storage write on the bucket. No service-account key, nothing stored.
 *
 * Install (once, by someone who receives the email and can write to the bucket):
 *   1. script.google.com → New project → paste this file. In Project Settings,
 *      tick "Show appsscript.json", then replace that manifest with:
 *        {
 *          "timeZone": "America/New_York",
 *          "oauthScopes": [
 *            "https://www.googleapis.com/auth/gmail.modify",
 *            "https://www.googleapis.com/auth/devstorage.read_write",
 *            "https://www.googleapis.com/auth/script.external_request"
 *          ],
 *          "exceptionLogging": "STACKDRIVER",
 *          "runtimeVersion": "V8"
 *        }
 *   2. Run `copyStatementsToDrop` once by hand and accept the consent prompt.
 *   3. Triggers → add a time-driven trigger: daily, any hour. The search is
 *      bounded to 40 days and labelled messages are skipped, so running
 *      every day costs nothing and catches a late statement.
 *
 * The bucket name is the VENDOR_DROP_BUCKET repo variable (see
 * docs/vendor-reports.md); the installing user needs objectCreator on it,
 * which `./scripts/09-vendor-drop.sh livewire grant <email>` sets.
 */

const BUCKET = 'livewire-dw-vendor-drops';
const PREFIX = 'securitycentral/statement/';
const LABEL = 'warehouse/dropped';
// Matched against what Security Central sends. Tighten the sender once the
// AP ticketing forward is out of the loop (today it arrives via ap@).
const QUERY = 'subject:"Statement EMail" "Security Central" has:attachment filename:pdf newer_than:40d';

function copyStatementsToDrop() {
  const label = GmailApp.getUserLabelByName(LABEL) || GmailApp.createLabel(LABEL);
  const threads = GmailApp.search(`${QUERY} -label:${LABEL.replace('/', '-')}`);
  let copied = 0;
  for (const thread of threads) {
    for (const message of thread.getMessages()) {
      for (const att of message.getAttachments({includeInlineImages: false})) {
        // The statement is the only PDF on the message; anything else that
        // rides along (a stray .docx has) is ignored.
        if (!/\.pdf$/i.test(att.getName()) && att.getContentType() !== 'application/pdf') continue;
        upload(att, message.getDate());
        copied++;
      }
    }
    thread.addLabel(label);
  }
  console.log(`copied ${copied} statement(s) to gs://${BUCKET}/${PREFIX}`);
}

function upload(att, receivedAt) {
  // Keep the vendor's own file name (000312-20261025.pdf, which is the
  // account and statement date) and prefix the receipt date so two uploads
  // of the same statement never collide. The pipeline keys on content, not
  // on the file name, so re-uploads are harmless either way.
  const stamp = Utilities.formatDate(receivedAt, 'UTC', 'yyyyMMdd');
  const name = `${PREFIX}${stamp}-${att.getName().replace(/[^\w.\-]/g, '_')}`;
  const url = `https://storage.googleapis.com/upload/storage/v1/b/${BUCKET}/o`
            + `?uploadType=media&name=${encodeURIComponent(name)}`;
  const res = UrlFetchApp.fetch(url, {
    method: 'post',
    contentType: 'application/pdf',
    payload: att.getBytes(),
    headers: {Authorization: `Bearer ${ScriptApp.getOAuthToken()}`},
    muteHttpExceptions: true,
  });
  if (res.getResponseCode() >= 300) {
    throw new Error(`upload of ${name} failed: ${res.getResponseCode()} ${res.getContentText()}`);
  }
  console.log(`uploaded gs://${BUCKET}/${name} (${att.getBytes().length} bytes)`);
}
