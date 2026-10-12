// The colour field takes typed input only: a paste would read the whole clipboard
// offer before its seven-character limit applies (marketplace review on #10862).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const qml = fs.readFileSync(path.join(__dirname, '..', 'Ombre.qml'), 'utf8');

test('colour field blocks clipboard paste and keeps its 7-character limit', () => {
  const field = qml.split('component ColorField: Rectangle {')[1].split('\n  component ')[0];
  assert.match(field, /maximumLength: 7/);
  assert.match(field, /event\.matches\(StandardKey\.Paste\)/);
  assert.match(field, /Qt\.Key_Insert && \(event\.modifiers & Qt\.ShiftModifier\)/);
  assert.match(field, /event\.accepted = true/);
  assert.equal((qml.match(/\bTextInput \{/g) || []).length, 1, 'any other raw TextInput needs the same guard');
});
