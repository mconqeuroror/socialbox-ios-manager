const $ = id => document.getElementById(id);
let csrfToken = '', offset = 0, total = 0, records = [], newKeys = [], requestPending = false;
let noticeTimer;
function notify(message, error = false) {
  clearTimeout(noticeTimer); $('notice').textContent = message; $('notice').classList.toggle('error', error); $('notice').hidden = false;
  noticeTimer = setTimeout(() => { $('notice').hidden = true; }, error ? 10000 : 5000);
}
function clearKeys() { newKeys = []; $('keys-output').value = ''; $('new-keys').hidden = true; }
function showLogin() {
  csrfToken = ''; clearKeys(); records = []; $('license-rows').replaceChildren(); $('dashboard').hidden = true; $('login-panel').hidden = false; $('logout').hidden = true; $('loading').hidden = true;
}
async function api(path, body) {
  const response = await fetch(`/api/${path}`, { method: body === undefined ? 'GET' : 'POST', credentials: 'same-origin', cache: 'no-store', headers: body === undefined ? {} : { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  const data = await response.json();
  if (!response.ok) {
    if (response.status === 401 && path !== 'login') showLogin();
    const retry = response.status === 429 ? ` Try again in ${response.headers.get('retry-after') || '60'} seconds.` : '';
    throw new Error((data.error || 'Request failed') + retry);
  }
  return data;
}
function dateLabel(value) {
  return value ? new Date(value).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : '—';
}
function textCell(value, className) {
  const cell = document.createElement('td'); cell.textContent = value; if (className) cell.className = className; return cell;
}
function renderRows() {
  const rows = records.map(record => {
    const tr = document.createElement('tr'), license = document.createElement('td'), key = document.createElement('span'), note = document.createElement('span');
    key.className = 'key-value'; key.textContent = record.maskedKey;
    note.className = 'key-note'; note.textContent = record.note || 'No note'; license.append(key, note); tr.append(license);
    const status = document.createElement('td'), badge = document.createElement('span'); badge.className = `badge ${record.status}`; badge.textContent = record.status; status.append(badge); tr.append(status);
    tr.append(textCell(`${record.days} days`), textCell(dateLabel(record.activatedAt)), textCell(dateLabel(record.expiresAt)), textCell(dateLabel(record.lastCheckIn)));
    const actionsCell = document.createElement('td'), actions = document.createElement('div'); actions.className = 'actions';
    const edit = document.createElement('button'); edit.className = 'quiet'; edit.textContent = 'Edit note'; edit.addEventListener('click', () => editNote(record)); actions.append(edit);
    const revoke = document.createElement('button'); revoke.className = 'quiet revoke'; revoke.textContent = record.status === 'revoked' ? 'Revoked' : 'Revoke'; revoke.disabled = record.status === 'revoked'; revoke.addEventListener('click', () => revokeKey(record)); actions.append(revoke);
    actionsCell.append(actions); tr.append(actionsCell); return tr;
  });
  $('license-rows').replaceChildren(...rows); $('empty').hidden = total > 0; $('total').textContent = total.toLocaleString();
  $('page-info').textContent = total ? `${offset + 1}–${Math.min(offset + records.length, total)} of ${total}` : '0 licenses';
  $('previous').disabled = offset === 0; $('next').disabled = offset + 50 >= total;
}
async function loadLicenses() {
  const data = await api(`licenses?offset=${offset}`); records = data.licenses; total = data.total; renderRows();
}
async function showDashboard() {
  $('loading').hidden = true; $('login-panel').hidden = true; $('dashboard').hidden = false; $('logout').hidden = false;
  await loadLicenses();
}
async function guarded(button, action) {
  if (requestPending) return;
  requestPending = true; const wasDisabled = button.disabled; button.disabled = true;
  try { await action(); } catch (error) { notify(error.message || 'Service unavailable', true); }
  finally { requestPending = false; if (button.isConnected) button.disabled = wasDisabled; }
}
$('login-form').addEventListener('submit', event => {
  event.preventDefault(); guarded(event.submitter, async () => {
    try { const data = await api('login', { email: $('email').value, password: $('password').value }); csrfToken = data.csrfToken; await showDashboard(); }
    finally { $('password').value = ''; }
  });
});
$('duration').addEventListener('change', () => { $('custom-days-label').hidden = $('duration').value !== 'custom'; $('custom-days').required = $('duration').value === 'custom'; });
$('generate-form').addEventListener('submit', event => {
  event.preventDefault(); guarded(event.submitter, async () => {
    if (newKeys.length && !confirm('The currently displayed keys will be replaced. Have you saved them?')) return;
    const days = Number($('duration').value === 'custom' ? $('custom-days').value : $('duration').value);
    const data = await api('generate', { count: Number($('count').value), days, note: $('note').value });
    newKeys = data.licenses.map(item => item.key); $('keys-output').value = newKeys.join('\n'); $('new-keys').hidden = false;
    $('new-keys').scrollIntoView({ behavior: 'smooth', block: 'center' }); notify(`${newKeys.length} license${newKeys.length === 1 ? '' : 's'} created. Save the keys now.`);
    offset = 0; await loadLicenses();
  });
});
$('copy-keys').addEventListener('click', () => guarded($('copy-keys'), async () => {
  try { await navigator.clipboard.writeText(newKeys.join('\n')); notify('Keys copied.'); }
  catch { $('keys-output').select(); notify('Select and copy the keys from the text area.', true); }
}));
$('download-keys').addEventListener('click', () => {
  const blob = new Blob([newKeys.join('\n') + '\n'], { type: 'text/plain' }), url = URL.createObjectURL(blob), link = document.createElement('a');
  link.href = url; link.download = `socialbox-licenses-${new Date().toISOString().slice(0, 10)}.txt`; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
});
$('close-keys').addEventListener('click', () => { if (confirm('Close and remove the full keys from this page? Make sure you saved them.')) clearKeys(); });
async function editNote(record) {
  if (requestPending) return;
  const note = prompt('Note / label (maximum 240 characters)', record.note); if (note === null) return;
  if (note.length > 240) { notify('Note must be at most 240 characters.', true); return; }
  await guarded($('refresh'), async () => { await api('note', { id: record.id, note }); await loadLicenses(); notify('Note saved.'); });
}
async function revokeKey(record) {
  if (requestPending || !confirm(`Revoke ${record.maskedKey}? This is permanent. Online checks will fail immediately; an offline installation can use its existing signed proof for up to 72 hours.`)) return;
  await guarded($('refresh'), async () => { await api('revoke', { id: record.id }); await loadLicenses(); notify('License revoked.'); });
}
$('refresh').addEventListener('click', () => guarded($('refresh'), loadLicenses));
$('previous').addEventListener('click', () => guarded($('refresh'), async () => { offset = Math.max(0, offset - 50); await loadLicenses(); }));
$('next').addEventListener('click', () => guarded($('refresh'), async () => { offset += 50; await loadLicenses(); }));
$('logout').addEventListener('click', () => guarded($('logout'), async () => { if (newKeys.length && !confirm('Sign out and clear the displayed keys? Save them first.')) return; await api('logout', {}); showLogin(); }));
window.addEventListener('beforeunload', event => { if (newKeys.length) { event.preventDefault(); event.returnValue = ''; } });
try {
  const session = await api('session');
  if (session.authenticated) { csrfToken = session.csrfToken; await showDashboard(); }
  else showLogin();
} catch (error) { showLogin(); notify(error.message || 'Unable to connect. Try refreshing.', true); }
