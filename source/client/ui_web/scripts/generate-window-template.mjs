import {readFile, mkdir, writeFile} from 'node:fs/promises';
const directory = new URL('../ts/core/window/', import.meta.url);
const html = (await readFile(new URL('templates/ui-window.html', directory), 'utf8')).replaceAll('\r\n', '\n');
const output = new URL('generated/ui-window-template.ts', directory);
await mkdir(new URL('generated/', directory), {recursive: true});
const source = '// Generated from templates/ui-window.html. Edit the HTML source.\nexport const windowTemplate = ' + JSON.stringify(html) + ';\n';
// Avoid rewriting unchanged source on every check.
if (await readFile(output, 'utf8').catch(() => null) !== source) await writeFile(output, source, 'utf8');
