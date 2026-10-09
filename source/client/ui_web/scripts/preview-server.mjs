import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const uiRoot = fileURLToPath(new URL('../', import.meta.url));
const webRoot = path.join(uiRoot, 'web');
const devFiles = new Map([
  ['index.html', path.join(uiRoot, 'dev/index.html')],
  ['preview.css', path.join(uiRoot, 'dev/preview.css')],
  ['controls.js', path.join(uiRoot, '.dev/controls.js')],
  ['runtime.js', path.join(uiRoot, '.dev/runtime.js')],
]);
const mime = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
};
export function createPreviewServer() {
  return createServer(async (req, res) => {
    try {
      if (req.method !== 'GET' && req.method !== 'HEAD') {
        res.writeHead(405);
        res.end();
        return;
      }
      let pathname = decodeURIComponent(
        new URL(req.url ?? '/', 'http://localhost').pathname,
      );
      if (pathname === '/') {
        res.writeHead(302, { Location: '/__dev/index.html' });
        res.end();
        return;
      }
      // Keep one module URL for the application shared by preview screens.
      if (pathname === '/inventory/game.html') {
        res.writeHead(302, { Location: '/web/inventory/game.html' });
        res.end();
        return;
      }
      let file;
      if (pathname.startsWith('/__dev/'))
        file = devFiles.get(pathname.slice('/__dev/'.length));
      else {
        if (pathname.startsWith('/web/')) pathname = pathname.slice(4);
        file = path.resolve(webRoot, '.' + pathname);
        if (!file.startsWith(webRoot + path.sep) || file.endsWith('.d.ts'))
          file = undefined;
      }
      if (!file) {
        res.writeHead(404);
        res.end();
        return;
      }
      let content = await readFile(file);
      // Inject only in the loopback preview response. The production file/CSP stay intact.
      if (file === path.join(webRoot, 'inventory/game.html'))
        content = Buffer.from(
          content
            .toString('utf8')
            .replace(
              '<script type="module" src="game.js">',
              '<script type="module" src="/__dev/runtime.js"></script><script type="module" src="game.js">',
            ),
        );
      res.writeHead(200, {
        'Content-Type': mime[path.extname(file)] ?? 'application/octet-stream',
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
      });
      res.end(req.method === 'HEAD' ? undefined : content);
    } catch {
      res.writeHead(404);
      res.end();
    }
  });
}
