// Node >=22, from Nix. Real browser checks, without third-party JS packages.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, readdir, realpath, rm, access } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const here = dirname(fileURLToPath(import.meta.url));
const packageRoot = await realpath(resolve(process.argv[2] ?? 'chromix-next-result'));
const info = JSON.parse(await readFile(join(packageRoot, 'share/chromix/build-info.json')));
assert.equal(info.features.defaultProfileDirectory, 'chromix');
assert.equal(info.features.hevcSoftwareDecoder, true);
const fixtures = await Promise.all(['main', 'main10'].map(async name => {
  const fixture = JSON.parse(await readFile(join(here, 'tests/data', `hevc-${name}.json`)));
  const mp4 = await readFile(join(here, 'tests/data', fixture.mp4));
  assert.equal(createHash('sha256').update(mp4).digest('hex'), fixture.sha256);
  return { ...fixture, name, mp4: mp4.toString('base64') };
}));

async function timed(promise, milliseconds, label) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} timed out`)), milliseconds);
    })]);
  } finally {
    clearTimeout(timer);
  }
}

class CDP {
  nextId = 0;
  pending = new Map();
  constructor(socket) {
    this.socket = socket;
    socket.addEventListener('message', event => {
      const message = JSON.parse(event.data);
      const request = this.pending.get(message.id);
      if (!request) return;
      this.pending.delete(message.id);
      if (message.error) request.reject(new Error(JSON.stringify(message.error)));
      else request.resolve(message.result);
    });
  }
  async call(method, params = {}) {
    const id = ++this.nextId;
    try {
      return await timed(new Promise((resolve, reject) => {
        this.pending.set(id, { resolve, reject });
        this.socket.send(JSON.stringify({ id, method, params }));
      }), 30000, method);
    } finally {
      this.pending.delete(id);
    }
  }
}

// This function runs inside the actual renderer, not in Node.
async function checkMedia(fixtures, blocked) {
  const bytes = text => Uint8Array.from(atob(text), char => char.charCodeAt(0));
  const deadline = (promise, label) => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label} timed out`)), 12000);
    promise.then(value => { clearTimeout(timer); resolve(value); },
      error => { clearTimeout(timer); reject(error); });
  });
  const results = [];
  for (const fixture of fixtures) {
    const config = { codec: fixture.codec, codedWidth: fixture.width,
      codedHeight: fixture.height, description: bytes(fixture.description),
      hardwareAcceleration: 'prefer-software' };
    const supported = (await VideoDecoder.isConfigSupported(config)).supported;
    const type = `video/mp4; codecs="${fixture.codec}"`;
    const video = document.createElement('video');
    const canPlay = video.canPlayType(type);
    const capability = await navigator.mediaCapabilities.decodingInfo({ type: 'file',
      video: { contentType: type, width: fixture.width, height: fixture.height,
        bitrate: 20000, framerate: 2 } });
    if (blocked) {
      if (supported || canPlay || capability.supported)
        throw new Error(`HEVC disabled policy ignored: ${fixture.name}`);
      results.push({ profile: fixture.name, blocked: true });
      continue;
    }
    if (!supported || !canPlay || !capability.supported)
      throw new Error(`HEVC capability missing: ${fixture.name}`);
    const frames = [];
    let decoderError;
    const decoder = new VideoDecoder({ error: error => { decoderError = error; },
      output: frame => {
        try {
          const canvas = new OffscreenCanvas(frame.displayWidth, frame.displayHeight);
          const context = canvas.getContext('2d');
          context.drawImage(frame, 0, 0);
          frames.push([...context.getImageData(16, 16, 1, 1).data]);
        } finally { frame.close(); }
      } });
    decoder.configure(config);
    decoder.decode(new EncodedVideoChunk({ type: 'key', timestamp: 0,
      data: bytes(fixture.sample) }));
    await deadline(decoder.flush(), 'WebCodecs decode');
    decoder.close();
    if (decoderError) throw decoderError;
    if (frames.length !== 1 || frames[0][0] < 180 || frames[0][1] > 70 || frames[0][2] > 70)
      throw new Error(`unexpected decoded pixel: ${JSON.stringify(frames)}`);
    const url = URL.createObjectURL(new Blob([bytes(fixture.mp4)], { type: 'video/mp4' }));
    try {
      const loaded = new Promise((resolve, reject) => {
        video.onloadeddata = resolve;
        video.onerror = () => reject(new Error(`HTML video error ${video.error?.code}`));
      });
      video.preload = 'auto';
      video.src = url;
      await deadline(loaded, 'HTML HEVC decode');
      const canvas = new OffscreenCanvas(fixture.width, fixture.height);
      const context = canvas.getContext('2d');
      context.drawImage(video, 0, 0);
      const pixel = [...context.getImageData(16, 16, 1, 1).data];
      if (pixel[0] < 180 || pixel[1] > 70 || pixel[2] > 70)
        throw new Error(`unexpected HTML video pixel: ${pixel}`);
      results.push({ profile: fixture.name, webCodecs: 'decoded', htmlVideo: 'decoded',
        mediaCapabilities: 'supported', pixel, softwarePreferred: true });
    } finally { video.removeAttribute('src'); video.load(); URL.revokeObjectURL(url); }
  }
  return results;
}

async function session(blocked) {
  const temporary = await mkdtemp(join(tmpdir(), 'chromix-features-'));
  const configHome = join(temporary, 'config');
  const profile = join(configHome, 'chromix');
  const headlessContainer = join(configHome, 'chromix-headless');
  const environment = { ...process.env, HOME: temporary, XDG_CONFIG_HOME: configHome,
    XDG_CACHE_HOME: join(temporary, 'cache') };
  delete environment.CHROME_CONFIG_HOME;
  delete environment.CHROME_USER_DATA_DIR;
  // A loopback HTTP origin is trustworthy, so secure-context WebCodecs APIs
  // are exposed without depending on about:blank's opaque-origin behavior.
  const server = createServer((_, response) => {
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    response.end('<!doctype html><title>Chromix feature verification</title>');
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  let stderr = '';
  const args = ['--headless', '--disable-gpu', '--disable-background-networking',
    '--disable-accelerated-video-decode',
    '--disable-dev-shm-usage', '--no-first-run', '--no-default-browser-check',
    '--remote-debugging-port=0'];
  if (blocked) args.push('--uxr-codec-hevc=disabled');
  const pageURL = `http://127.0.0.1:${server.address().port}/`;
  args.push(pageURL);
  const browser = spawn(join(packageRoot, 'bin/chromix'), args,
    { env: environment, detached: true, stdio: ['ignore', 'ignore', 'pipe'] });
  browser.stderr.on('data', data => { stderr = (stderr + data).slice(-8000); });
  let spawnError;
  browser.on('error', error => { spawnError = error; });
  let socket;
  try {
    const portFile = join(profile, 'DevToolsActivePort');
    let port;
    for (let attempt = 0; attempt < 300; attempt++) {
      if (spawnError) throw spawnError;
      if (browser.exitCode !== null) throw new Error(`browser exited: ${stderr}`);
      // M154 headless derives an ephemeral container from the real default
      // directory: chromix-headless/scoped_dir*/DevToolsActivePort.
      const candidates = [portFile];
      try {
        for (const name of await readdir(headlessContainer)) {
          candidates.push(join(headlessContainer, name, 'DevToolsActivePort'));
        }
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
      for (const candidate of candidates) {
        try {
          port = Number((await readFile(candidate, 'utf8')).split('\n')[0]);
          break;
        } catch (error) { if (error.code !== 'ENOENT') throw error; }
      }
      if (port) break;
      try {
        await access(join(configHome, 'chromium-headless'));
        throw new Error('browser still uses the chromium default directory');
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
      await sleep(100);
    }
    assert.ok(port > 0, `missing default chromix profile: ${stderr}`);
    // A separate default directory, not a forced --user-data-dir argument.
    // Crash reporting can create a brand-level directory independently of the
    // user profile. Reject actual profile state, not an empty auxiliary folder.
    for (const artifact of ['DevToolsActivePort', 'Local State', 'Default/Preferences']) {
      await assert.rejects(access(join(configHome, 'chromium', artifact)), { code: 'ENOENT' });
    }
    const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    socket = new WebSocket(targets.find(target => target.type === 'page').webSocketDebuggerUrl);
    await timed(new Promise((resolve, reject) => {
      socket.addEventListener('open', resolve, { once: true });
      socket.addEventListener('error', reject, { once: true });
    }), 5000, 'CDP connection');
    const cdp = new CDP(socket);
    // The debug endpoint may become available before the loopback page loads.
    for (let attempt = 0; attempt < 100; attempt++) {
      const state = await cdp.call('Runtime.evaluate', {
        expression: '({url:location.href, ready:document.readyState})', returnByValue: true,
      });
      if (state.result.value.url === pageURL && state.result.value.ready === 'complete') break;
      if (attempt === 99) throw new Error('feature test page did not load');
      await sleep(100);
    }
    const result = await cdp.call('Runtime.evaluate', {
      expression: `(${checkMedia.toString()})(${JSON.stringify(fixtures)}, ${blocked})`,
      awaitPromise: true, returnByValue: true, userGesture: true,
    });
    assert.ok(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
    assert.ok(!stderr.includes('GLib-GIO-CRITICAL'), stderr);
    return result.result.value;
  } finally {
    socket?.close();
    if (browser.pid) {
      try { process.kill(-browser.pid, 'SIGKILL'); }
      catch (error) { if (error.code !== 'ESRCH') throw error; }
      await timed(new Promise(resolve => {
        if (browser.exitCode !== null || browser.signalCode) resolve();
        else browser.once('exit', resolve);
      }), 5000, 'browser shutdown');
    }
    await rm(temporary, { recursive: true, force: true });
    await new Promise(resolve => server.close(resolve));
  }
}

try {
  const decoded = await session(false);
  const disabledPolicy = await session(true);
  console.log(JSON.stringify({ status: 'passed', package: packageRoot, profile: info.profile,
    defaultProfileDirectory: 'chromix', hardwareDecodeDisabled: true,
    noSandboxFlagPassed: false, decoded, disabledPolicy }));
} catch (error) {
  console.log(JSON.stringify({ status: 'failed', error: String(error.stack ?? error) }));
  process.exitCode = 1;
}
