/**
 * Save vendor statements and invoices from Gmail to Drive, for the warehouse.
 *
 * Runs as the Gmail user who installs it (the vendors' emails reach them
 * through the ap@ group), once a day. The warehouse never reads a mailbox:
 * it reads only the Drive folders below, each shared Viewer with
 * ingest-vendor@livewire-dw.iam.gserviceaccount.com.
 *
 *   Security Central monthly statement  -> pipelines/scstatement/
 *   Parasol monthly invoice             -> pipelines/drivedrop/ (parasol/invoice)
 *
 * Install: script.google.com -> New project -> paste this file -> run
 * installDailyTrigger once and approve the access it asks for (read Gmail,
 * write Drive). Updating an installed copy: paste over it and save; the daily
 * trigger keeps calling saveSecurityCentralStatements, which runs every rule.
 *
 * A thread is labelled warehouse-saved once handled, and a PDF already in its
 * folder under the same name is not saved twice, so re-running is harmless.
 */
const LABEL = 'warehouse-saved';
const RULES = [
  {
    name: 'Security Central statement',
    folderId: '1xZ69hFsIiyeRpyHSAHbwgF6Zyb33tYxJ',
    // Arrives via the ap@ group, which rewrites the sender, so match on
    // Security Central's own subject and body line instead.
    query: 'subject:"Statement EMail" "alarm monitoring statement"',
  },
  {
    name: 'Parasol invoice',
    folderId: '1ySe-ZKAqJtMMcsQoVsqz9pV9N-MuzbJ2',
    // Parasol bills through 1Plan since October 2026, and its invoices now
    // arrive from more than one sender: accounting@getparasol.com ("Parasol's
    // May 2026 monthly invoice for: Livewire"), 1Plan, and ADI accounting
    // replying in a thread with accounting@getparasol.com on copy (the
    // October invoice, IN2129859, came that way on 2026-11-05). So match an
    // invoice email that mentions Parasol or comes from Parasol or 1Plan,
    // not one sender address.
    query: 'subject:invoice (Parasol OR from:getparasol.com OR from:1plan.net)',
    // Only invoice PDFs: 1Plan names them IN<number>.pdf. Anything else the
    // thread carries would make the nightly load fail as "parsed to no rows".
    fileName: /^(IN\d+|.*parasol.*|.*invoice.*)\.pdf$/i,
  },
];

function saveVendorDocuments() {
  const label = GmailApp.getUserLabelByName(LABEL) || GmailApp.createLabel(LABEL);
  for (const rule of RULES) {
    const folder = DriveApp.getFolderById(rule.folderId);
    const query = rule.query + ' has:attachment filename:pdf newer_than:120d -label:' + LABEL;
    for (const thread of GmailApp.search(query, 0, 20)) {
      for (const message of thread.getMessages()) {
        for (const attachment of message.getAttachments()) {
          const name = attachment.getName();
          if (!/\.pdf$/i.test(name)) continue;         // skip flyers and the like
          if (rule.fileName && !rule.fileName.test(name)) continue;
          if (folder.getFilesByName(name).hasNext()) continue;
          folder.createFile(attachment.copyBlob()).setName(name);
          console.log(rule.name + ': saved ' + name);
        }
      }
      thread.addLabel(label);
    }
  }
}

// The name the daily trigger was installed with; kept so an installed copy
// picks up new rules by pasting this file over it, with no new trigger.
function saveSecurityCentralStatements() {
  saveVendorDocuments();
}

function installDailyTrigger() {
  for (const t of ScriptApp.getProjectTriggers()) {
    if (t.getHandlerFunction() === 'saveSecurityCentralStatements' ||
        t.getHandlerFunction() === 'saveVendorDocuments') ScriptApp.deleteTrigger(t);
  }
  ScriptApp.newTrigger('saveSecurityCentralStatements').timeBased().everyDays(1).atHour(6).create();
  saveVendorDocuments();
}
