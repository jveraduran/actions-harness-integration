'use strict';

const http = require('http');

const PORT = process.env.PORT || 3000;

/**
 * Sin framework y sin dependencias externas a propósito: el objetivo de este
 * repo es producir un artefacto de contenedor real que pase por el gate de
 * hardening, no demostrar nada del stack de aplicación. El módulo http
 * nativo también evita el riesgo de incompatibilidad con la versión de Node
 * de la base image (ver el comentario en el Dockerfile original: v10).
 */

function healthPayload() {
  return JSON.stringify({ status: 'ok' });
}

/**
 * Expone la versión del artefacto y el BASE_TAG con el que se construyó
 * (inyectado como ENV desde el Dockerfile). Permite comprobar en caliente,
 * en un pod ya desplegado, qué base image trae, sin ir al registry.
 */
function versionPayload() {
  return JSON.stringify({
    app: 'hardening-reader-1-nodejs',
    version: process.env.npm_package_version || 'dev',
    base_tag: process.env.BASE_TAG || 'desconocido',
  });
}

function requestHandler(req, res) {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(healthPayload());
    return;
  }
  if (req.url === '/version') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(versionPayload());
    return;
  }
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found' }));
}

// Solo arranca el servidor si este archivo se ejecuta directamente (node
// server.js), no cuando lo importa el smoke test — así el test puede
// llamar a las funciones sin necesitar abrir un puerto real.
if (require.main === module) {
  http.createServer(requestHandler).listen(PORT, () => {
    console.log(`hardening-reader-1-nodejs escuchando en el puerto ${PORT}`);
    console.log(versionPayload());
  });
}

module.exports = { healthPayload, versionPayload, requestHandler };
