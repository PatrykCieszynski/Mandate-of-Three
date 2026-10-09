import { spawn } from 'node:child_process';
import { watch } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { createPreviewServer } from './preview-server.mjs';
const uiRoot = fileURLToPath(new URL('../', import.meta.url));
const compiler = fileURLToPath(
  new URL('../node_modules/typescript/bin/tsc', import.meta.url),
);
const generator = fileURLToPath(
  new URL('./generate-window-template.mjs', import.meta.url),
);
const args = process.argv.slice(2),
  portIndex = args.indexOf('--port');
const port = portIndex === -1 ? 4173 : Number(args[portIndex + 1]);
if (!Number.isInteger(port) || port < 0 || port > 65535)
  throw Error('Use --port <0..65535>');
const children = new Set();
let templateWatcher;
function run(args) {
  const child = spawn(process.execPath, args, {
    cwd: uiRoot,
    stdio: 'inherit',
    windowsHide: true,
  });
  children.add(child);
  child.on('exit', () => children.delete(child));
  return child;
}
async function build(args) {
  await new Promise((resolve, reject) => {
    const child = run(args);
    child.once('error', reject);
    child.once('exit', (code) =>
      code === 0 ? resolve() : reject(Error('Preview build failed')),
    );
  });
}
const server = createPreviewServer();
function stop() {
  templateWatcher?.close();
  for (const child of children) child.kill();
  server.close();
}
process.once('SIGINT', () => {
  stop();
  process.exit(0);
});
process.once('SIGTERM', () => {
  stop();
  process.exit(0);
});
process.once('exit', stop);
if (!args.includes('--serve-only')) {
  await build([generator]);
  await build([compiler, '-p', 'tsconfig.json']);
  await build([compiler, '-p', 'tsconfig.dev.json']);
  run([compiler, '-p', 'tsconfig.json', '--watch', '--preserveWatchOutput']);
  run([
    compiler,
    '-p',
    'tsconfig.dev.json',
    '--watch',
    '--preserveWatchOutput',
  ]);
  templateWatcher = watch(
    fileURLToPath(new URL('../ts/core/window/templates/', import.meta.url)),
    () => run([generator]),
  );
}
server.on('error', (error) => {
  console.error(error.message);
  stop();
  process.exit(1);
});
server.listen(port, '127.0.0.1', () => {
  const address = server.address();
  if (!address || typeof address === 'string')
    throw Error('Missing preview port');
  console.log(`Mandate UI preview: http://127.0.0.1:${address.port}/`);
  console.log(
    'Production UI + fixture IPC. No Godot or game server. Reload after TS recompiles; Ctrl+C stops.',
  );
});
