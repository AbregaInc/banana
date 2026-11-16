// Entries arrive newest first. A chart belongs to the input that requested it,
// even when two consecutive inputs happen to contain the same words.
export function nutritionInputId(entries) {
  const entry = entries.find(entry => entry.model?.some(message => message.role === 'user'));
  return entry ? String(entry.id) : null;
}
export function nutritionForInput(doc, inputId) {
  return doc?.inputId === inputId ? doc.surface ?? null : null;
}
