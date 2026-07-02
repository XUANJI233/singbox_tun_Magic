import net from 'node:net';

const host = process.env.SOCKS_HOST || '0.0.0.0';
const port = Number(process.env.SOCKS_PORT || 10808);

function closeBoth(a, b) {
  a.destroy();
  b?.destroy();
}

function readExact(socket, size) {
  return new Promise((resolve, reject) => {
    let chunks = [];
    let total = 0;

    function cleanup() {
      socket.off('readable', onReadable);
      socket.off('error', onError);
      socket.off('close', onClose);
    }

    function onError(err) {
      cleanup();
      reject(err);
    }

    function onClose() {
      cleanup();
      reject(new Error('socket closed'));
    }

    function onReadable() {
      let chunk;
      while ((chunk = socket.read(size - total)) !== null) {
        chunks.push(chunk);
        total += chunk.length;
        if (total === size) {
          cleanup();
          resolve(Buffer.concat(chunks, size));
          return;
        }
      }
    }

    socket.on('readable', onReadable);
    socket.on('error', onError);
    socket.on('close', onClose);
    onReadable();
  });
}

async function handleClient(client) {
  try {
    const greeting = await readExact(client, 2);
    const methods = await readExact(client, greeting[1]);
    if (greeting[0] !== 0x05 || !methods.includes(0x00)) {
      client.end(Buffer.from([0x05, 0xff]));
      return;
    }
    client.write(Buffer.from([0x05, 0x00]));

    const head = await readExact(client, 4);
    if (head[0] !== 0x05 || head[1] !== 0x01) {
      client.end(Buffer.from([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
      return;
    }

    let targetHost;
    if (head[3] === 0x01) {
      targetHost = [...await readExact(client, 4)].join('.');
    } else if (head[3] === 0x03) {
      const len = (await readExact(client, 1))[0];
      targetHost = (await readExact(client, len)).toString('utf8');
    } else if (head[3] === 0x04) {
      const raw = await readExact(client, 16);
      targetHost = raw.toString('hex').match(/.{1,4}/g).join(':');
    } else {
      client.end(Buffer.from([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
      return;
    }
    const targetPort = (await readExact(client, 2)).readUInt16BE(0);

    const upstream = net.connect({ host: targetHost, port: targetPort });
    upstream.once('connect', () => {
      client.write(Buffer.from([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
      client.pipe(upstream);
      upstream.pipe(client);
    });
    upstream.once('error', () => {
      client.end(Buffer.from([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
    });
    client.once('error', () => closeBoth(client, upstream));
    client.once('close', () => upstream.destroy());
    upstream.once('close', () => client.destroy());
  } catch (err) {
    client.destroy();
  }
}

const server = net.createServer((client) => {
  handleClient(client);
});

server.listen(port, host, () => {
  console.log(`socks5 listening on ${host}:${port}`);
});
