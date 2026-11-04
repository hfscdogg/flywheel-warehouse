/**
 * Save Security Central's monthly statement PDFs from Gmail to Drive.
 *
 * Runs as the Gmail user who installs it (the statement reaches them through
 * the ap@ group), once a day. The warehouse never reads a mailbox: it reads
 * only the Drive folder below, which is shared Viewer with
 * ingest-vendor@livewire-dw.iam.gserviceaccount.com
 * (pipelines/scstatement/ingest.py).
 *
 * Install: script.google.com -> New project -> paste this file -> run
 * installDailyTrigger once and approve the access it asks for (read Gmail,
 * write Drive). Running saveSecurityCentralStatements by hand also backfills
 * the last few months.
 *
 * A thread is labelled warehouse-saved once handled, and a PDF already in the
 * folder under the same name is not saved twice, so re-running is harmless.
 */
const FOLDER_ID = '1xZ69hFsIiyeRpyHSAHbwgF6Zyb33tYxJ';
const LABEL = 'warehouse-saved';
// The subject is Security Central's ("Statement EMail", prefixed by the ap@
// group's tag); the body line is theirs too. Both, so nothing else matches.
const QUERY = 'subject:"Statement EMail" "alarm monitoring statement" ' +
              'has:attachment filename:pdf newer_than:120d -label:' + LABEL;

function saveSecurityCentralStatements() {
  const folder = DriveApp.getFolderById(FOLDER_ID);
  const label = GmailApp.getUserLabelByName(LABEL) || GmailApp.createLabel(LABEL);
  for (const thread of GmailApp.search(QUERY, 0, 20)) {
    for (const message of thread.getMessages()) {
      for (const attachment of message.getAttachments()) {
        const name = attachment.getName();
        if (!/\.pdf$/i.test(name)) continue;           // skip the .docx flyers
        if (folder.getFilesByName(name).hasNext()) continue;
        folder.createFile(attachment.copyBlob()).setName(name);
        console.log('saved ' + name);
      }
    }
    thread.addLabel(label);
  }
}

function installDailyTrigger() {
  for (const t of ScriptApp.getProjectTriggers()) {
    if (t.getHandlerFunction() === 'saveSecurityCentralStatements') ScriptApp.deleteTrigger(t);
  }
  ScriptApp.newTrigger('saveSecurityCentralStatements').timeBased().everyDays(1).atHour(6).create();
  saveSecurityCentralStatements();
}
