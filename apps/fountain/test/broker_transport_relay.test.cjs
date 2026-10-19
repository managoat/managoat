'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const tls = require('node:tls');
const crypto = require('node:crypto');
const { execFile, execFileSync } = require('node:child_process');
const { promisify } = require('node:util');
const exec = promisify(execFile);
const relay = path.resolve(__dirname, '../priv/broker/transport-relay.cjs');
let controlPath;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function command(mode, config) {
  return exec('flock', ['-w', '30', `${config.controlDirectory}.lock`,
    process.execPath, relay, mode, JSON.stringify(config)], { timeout: 30_000 });
}

async function status() {
  return new Promise((resolve, reject) => {
    const socket = net.connect(controlPath, () => socket.end('status'));
    let data = '';
    socket.on('data', chunk => { data += chunk; });
    socket.on('end', () => resolve(JSON.parse(data)));
    socket.on('error', reject);
  });
}

async function until(check) {
  for (let i = 0; i < 100; i++) {
    if (await check()) return;
    await delay(50);
  }
  assert.fail('condition did not become true');
}

async function exchange(port, bytes) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1', () => socket.write(bytes));
    const chunks = [];
    let length = 0;
    socket.setTimeout(5000, () => socket.destroy(new Error('exchange timeout')));
    socket.on('data', data => {
      chunks.push(data);
      length += data.length;
      if (length === bytes.length) { socket.destroy(); resolve(Buffer.concat(chunks)); }
    });
    socket.on('error', reject);
    socket.on('end', () => { if (length !== bytes.length) reject(new Error('short exchange')); });
  });
}

test('transport relay integration', { timeout: 60_000 }, async t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-test-'));
  const controlDirectory = path.join(directory, 'control');
  controlPath = path.join(controlDirectory, 'control.sock');
  const cert = path.join(directory, 'cert.pem');
  const key = path.join(directory, 'key.pem');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', key, '-out', cert, '-days', '1', '-subj', '/CN=localhost',
    '-addext', 'subjectAltName=DNS:localhost'], { stdio: 'ignore' });
  const peers = new Set();
  const server = tls.createServer({ key: fs.readFileSync(key), cert: fs.readFileSync(cert) }, s => {
    peers.add(s);
    s.on('error', () => {});
    s.on('close', () => peers.delete(s));
    s.pipe(s);
  });
  // A readiness probe can connect and disappear before secureConnection.
  // tls.Server.close() waits for these raw sockets too, so owning only TLS
  // peers can hang teardown after every assertion has passed.
  server.on('connection', socket => {
    peers.add(socket);
    socket.on('close', () => peers.delete(socket));
  });
  server.on('tlsClientError', () => {});
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const portReservation = net.createServer();
  await new Promise(resolve => portReservation.listen(0, '127.0.0.1', resolve));
  const listen = portReservation.address().port;
  await new Promise(resolve => portReservation.close(resolve));
  const config = { host: 'localhost', port: server.address().port, listen,
    owner: 'conversation-test', ca: cert, controlDirectory };
  async function closeOrigin() {
    for (const peer of peers) peer.destroy();
    if (server.listening) await new Promise(resolve => server.close(resolve));
  }
  t.after(async () => {
    try { await command('stop', config); }
    finally {
      await closeOrigin();
      fs.rmSync(directory, { recursive: true });
    }
  });

  await t.test('ready only after verified TLS; idempotent ensure preserves the worker', async () => {
    await command('ensure', config);
    const before = await status();
    assert.equal(before.ready, true);
    await command('ensure', config);
    assert.equal((await status()).pid, before.pid);
    await assert.rejects(command('ensure', { ...config, owner: 'another-conversation' }));
    assert.equal((await status()).pid, before.pid);
  });

  await t.test('CONNECT and absolute-form HTTP bytes, including rotated tokens, are unchanged', async () => {
    for (const token of ['old-session', 'new-session']) {
      for (const request of ['CONNECT example.org:443 HTTP/1.1', 'GET http://example.org/x HTTP/1.1']) {
        const bytes = Buffer.from(`${request}\r\nProxy-Authorization: Basic ${token}\r\n\r\n`);
        assert.deepEqual(await exchange(listen, bytes), bytes);
      }
    }
  });

  await t.test('streams a large binary payload with backpressure', async () => {
    const bytes = crypto.randomBytes(8 * 1024 * 1024);
    assert.deepEqual(await exchange(listen, bytes), bytes);
  });

  await t.test('configuration replacement waits for the old worker to exit', async () => {
    const before = await status();
    // A stopped worker cannot handle SIGTERM; shutdown must wait for its
    // bounded SIGKILL fallback before another worker binds the same port.
    process.kill(before.workerPid, 'SIGSTOP');
    await command('ensure', { ...config, generation: 'replacement' });
    assert.notEqual((await status()).workerPid, before.workerPid);
    assert.deepEqual(await exchange(listen, Buffer.from('replacement')), Buffer.from('replacement'));
    await command('ensure', config);
  });

  await t.test('client half-close and slow response drain preserve every byte', async () => {
    const payload = crypto.randomBytes(4 * 1024 * 1024);
    const responsePeers = new Set();
    const responseServer = tls.createServer({ key: fs.readFileSync(key), cert: fs.readFileSync(cert),
      allowHalfOpen: true }, socket => {
      responsePeers.add(socket);
      socket.on('close', () => responsePeers.delete(socket));
      socket.on('error', () => {});
      socket.on('data', () => {});
      socket.on('end', () => socket.end(payload));
    });
    // A readiness probe can disconnect before secureConnection is emitted.
    // Track raw sockets too so the test origin's close cannot wait on one.
    responseServer.on('connection', socket => {
      responsePeers.add(socket);
      socket.on('close', () => responsePeers.delete(socket));
    });
    await new Promise(resolve => responseServer.listen(0, '127.0.0.1', resolve));
    try {
      await command('ensure', { ...config, port: responseServer.address().port });
      const received = await new Promise((resolve, reject) => {
        const socket = net.connect(listen, '127.0.0.1', () => socket.end('request'));
        const chunks = [];
        socket.on('data', chunk => {
          chunks.push(chunk);
          socket.pause();
          setTimeout(() => socket.resume(), 2);
        });
        socket.on('end', () => resolve(Buffer.concat(chunks)));
        socket.on('error', reject);
        socket.setTimeout(5000, () => socket.destroy(new Error('slow response timeout')));
      });
      assert.deepEqual(received, payload);
    } finally {
      try { await command('ensure', config); }
      finally {
        for (const socket of responsePeers) socket.destroy();
        await new Promise(resolve => responseServer.close(resolve));
      }
    }
  });

  await t.test('worker failure is supervised and subsequent connections recover', async () => {
    const before = await status();
    process.kill(before.workerPid, 'SIGKILL');
    await until(async () => {
      const next = await status();
      return next.ready && next.workerPid !== before.workerPid;
    });
    assert.deepEqual(await exchange(listen, Buffer.from('after restart')), Buffer.from('after restart'));
  });

  await t.test('stop closes the listener; wake starts a new ready worker', async () => {
    await command('stop', config);
    await assert.rejects(exchange(listen, Buffer.from('stopped')));
    await command('ensure', config);
    assert.deepEqual(await exchange(listen, Buffer.from('awake')), Buffer.from('awake'));
  });

  await t.test('a supervisor exiting mid-request counts as gone, not as a failure (#3021)', async () => {
    await command('stop', config);
    // Stand-ins for a supervisor that exits with a status or stop request in
    // flight: it either ends the connection unanswered or closes it with the
    // request unread, which the client reads as ECONNRESET.
    const exits = {
      unanswered: socket => { socket.resume(); socket.end(); },
      reset: socket => setTimeout(() => socket.destroy(), 100)
    };
    for (const [name, hangUp] of Object.entries(exits)) {
      for (const mode of ['ensure', 'stop']) {
        const exiting = net.createServer({ pauseOnConnect: true }, socket => {
          socket.on('error', () => {});
          exiting.close();
          hangUp(socket);
        });
        await new Promise(resolve => exiting.listen(controlPath, resolve));
        try {
          await assert.doesNotReject(command(mode, config), `${mode} after a supervisor ${name} exit`);
        } finally { if (exiting.listening) exiting.close(); }
        await command('stop', config);
      }
    }
    await command('ensure', config);
    assert.equal((await status()).ready, true);
  });

  await t.test('a live supervisor that hangs up once is asked again, never replaced (#3021)', async () => {
    await command('stop', config);
    // A supervisor stalled past its 1 s request timeout resets the
    // connection but keeps its socket. Treating that as gone would unlink
    // the live socket and orphan it; it must be asked again instead.
    async function stalled(reply) {
      let connections = 0;
      const live = net.createServer({ pauseOnConnect: true }, socket => {
        socket.on('error', () => {});
        if (++connections === 1) return setTimeout(() => socket.destroy(), 100);
        socket.resume();
        socket.end(JSON.stringify(reply));
      });
      await new Promise(resolve => live.listen(controlPath, resolve));
      return { live, connections: () => connections };
    }
    const another = await stalled({ owner: 'another-conversation' });
    try {
      await assert.rejects(command('ensure', config));
      assert.equal(fs.existsSync(controlPath), true);
      assert.equal(another.connections(), 2);
    } finally { another.live.close(); }

    const stopping = await stalled({ owner: config.owner });
    stopping.live.on('connection', () => {
      if (stopping.connections() === 2) stopping.live.close();
    });
    try {
      await command('stop', config);
      assert.equal(stopping.connections(), 2);
    } finally { if (stopping.live.listening) stopping.live.close(); }
    // A wrongly started supervisor must not outlive this case.
    await command('stop', config);

    await command('ensure', config);
    assert.equal((await status()).ready, true);
  });

  await t.test('supervisor loss closes the worker; ensure repairs the stale socket', async () => {
    const before = await status();
    process.kill(before.pid, 'SIGKILL');
    await until(async () => {
      try { await exchange(listen, Buffer.from('probe')); return false; }
      catch (_) { return true; }
    });
    await command('ensure', config);
    assert.notEqual((await status()).pid, before.pid);
    assert.deepEqual(await exchange(listen, Buffer.from('repaired')), Buffer.from('repaired'));
  });

  await t.test('hostname mismatch fails closed, even with a trusted certificate', async () => {
    await command('stop', config);
    await assert.rejects(command('ensure', { ...config, host: '127.0.0.1' }));
    await assert.rejects(exchange(listen, Buffer.from('must not forward')));
  });

  await t.test('untrusted certificate fails closed', async () => {
    await assert.rejects(command('ensure', { ...config, ca: '/etc/ssl/certs/ca-certificates.crt' }));
    await assert.rejects(exchange(listen, Buffer.from('must not forward')));
  });
  await t.test('origin teardown closes a connection that has not started TLS', async () => {
    const connected = new Promise(resolve => server.once('connection', resolve));
    const socket = net.connect(server.address().port, '127.0.0.1');
    socket.on('error', () => {});
    await connected;
    const closed = new Promise(resolve => socket.once('close', resolve));
    let timer;
    try {
      await Promise.race([
        Promise.all([closeOrigin(), closed]),
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error('origin teardown left a pre-handshake socket alive')), 1000);
        })
      ]);
    } finally {
      clearTimeout(timer);
      socket.destroy();
    }
  });

});
