#!/usr/bin/env node
/**
 * PutObject to Cloudflare R2 via the S3-compatible API (AWS SigV4).
 * Uses only Node built-ins — no npm dependencies.
 *
 * Usage:
 *   put-r2-s3.mjs --endpoint <url> --bucket <name> --key <path> \
 *     --file <local-path> --content-type <mime> \
 *     --access-key-id <id> --secret-access-key <secret>
 */
import fs from 'node:fs';
import crypto from 'node:crypto';
import https from 'node:https';
import { URL } from 'node:url';

const REGION = 'auto';
const SERVICE = 's3';

function usage(msg) {
  if (msg) console.error(`error: ${msg}`);
  console.error(`usage: put-r2-s3.mjs --endpoint <url> --bucket <name> --key <path> \\
  --file <local-path> --content-type <mime> \\
  --access-key-id <id> --secret-access-key <secret>`);
  process.exit(msg ? 1 : 2);
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) usage(`unknown argument: ${a}`);
    const key = a.slice(2);
    const val = argv[++i];
    if (val === undefined || val.startsWith('--')) usage(`missing value for --${key}`);
    out[key] = val;
  }
  for (const k of ['endpoint', 'bucket', 'key', 'file', 'content-type', 'access-key-id', 'secret-access-key']) {
    if (!out[k]) usage(`--${k} is required`);
  }
  return out;
}

function hmac(key, data, encoding) {
  return crypto.createHmac('sha256', key).update(data, 'utf8').digest(encoding);
}

function sha256Hex(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}

function signingKey(secret, dateStamp) {
  let k = hmac(`AWS4${secret}`, dateStamp);
  k = hmac(k, REGION);
  k = hmac(k, SERVICE);
  return hmac(k, 'aws4_request');
}

function signRequest({ method, url, headers, body, accessKeyId, secretAccessKey }) {
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);

  const payloadHash = sha256Hex(body);
  const signedHeaders = Object.keys(headers).sort().map((k) => k.toLowerCase()).join(';');
  const canonicalHeaders = Object.keys(headers)
    .sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()))
    .map((k) => `${k.toLowerCase()}:${String(headers[k]).trim()}\n`)
    .join('');

  const canonicalRequest = [
    method,
    url.pathname,
    url.search ? url.search.slice(1) : '',
    canonicalHeaders,
    signedHeaders,
    payloadHash,
  ].join('\n');

  const credentialScope = `${dateStamp}/${REGION}/${SERVICE}/aws4_request`;
  const stringToSign = [
    'AWS4-HMAC-SHA256',
    amzDate,
    credentialScope,
    sha256Hex(canonicalRequest),
  ].join('\n');

  const signature = hmac(signingKey(secretAccessKey, dateStamp), stringToSign, 'hex');
  const authorization = [
    `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${credentialScope}`,
    `SignedHeaders=${signedHeaders}`,
    `Signature=${signature}`,
  ].join(', ');

  return {
    ...headers,
    'x-amz-date': amzDate,
    'x-amz-content-sha256': payloadHash,
    Authorization: authorization,
  };
}

function putObject(opts) {
  const endpoint = opts.endpoint.replace(/\/$/, '');
  const objectUrl = new URL(`${endpoint}/${opts.bucket}/${opts.key}`);
  const body = fs.readFileSync(opts.file);

  const baseHeaders = {
    Host: objectUrl.host,
    'Content-Type': opts['content-type'],
    'Content-Length': String(body.length),
  };

  const headers = signRequest({
    method: 'PUT',
    url: objectUrl,
    headers: baseHeaders,
    body,
    accessKeyId: opts['access-key-id'],
    secretAccessKey: opts['secret-access-key'],
  });

  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        method: 'PUT',
        hostname: objectUrl.hostname,
        path: objectUrl.pathname + objectUrl.search,
        headers,
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          if (res.statusCode >= 200 && res.statusCode < 300) {
            resolve();
          } else {
            reject(new Error(`S3 PutObject failed (${res.statusCode}): ${text || res.statusMessage}`));
          }
        });
      },
    );
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

const opts = parseArgs(process.argv.slice(2));
putObject(opts).catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});