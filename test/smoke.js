'use strict';

const assert = require('assert');
const { healthPayload, versionPayload, requestHandler } = require('../server.js');

// /health responde ok
assert.strictEqual(JSON.parse(healthPayload()).status, 'ok');

// /version expone los campos de trazabilidad que necesita el gate
const version = JSON.parse(versionPayload());
assert.strictEqual(version.app, 'hardening-reader-1-nodejs');
assert.ok('base_tag' in version, 'debe exponer base_tag para trazabilidad');

// requestHandler responde 404 en una ruta desconocida, sin tirar el proceso
{
  let statusSeen = null;
  const fakeReq = { url: '/no-existe' };
  const fakeRes = {
    writeHead(status) { statusSeen = status; },
    end() {},
  };
  requestHandler(fakeReq, fakeRes);
  assert.strictEqual(statusSeen, 404);
}

console.log('smoke test OK: 3 comprobaciones pasaron');
