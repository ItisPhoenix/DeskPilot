/**
 * An SVG is text (XML). read_file and read_multiple_files list the images they
 * show as images (PNG, JPEG, GIF, WebP), but the file handlers took every .svg
 * for an image: read_file answered an image block instead of the SVG's text,
 * and write_file and edit_block base64-decoded the text they were given, so a
 * 41-character SVG became 6 garbage bytes, with "Successfully wrote".
 *
 * Expected: the tools read and write an .svg as the text it is. The file
 * preview widget still draws an SVG as an image: its own read (origin 'ui')
 * gets the file's bytes as base64, as before.
 *
 * Server-side URL reads are disabled for both SVG and PNG URLs.
 * Runs the real server over stdio, as a client does.
 */
import assert from 'assert';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { runIfMain } from './helpers/run-if-main.js';
import { closeClient, connectToServer } from './helpers/mcp-client.js';

const SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1"/></svg>';

const textOf = (result) => (result.content ?? []).filter((block) => block.type === 'text').map((block) => block.text).join('\n');
const blockTypes = (result) => JSON.stringify((result.content ?? []).map((block) => block.type));


async function readFileAnswersTheText(client, dir) {
  const file = path.join(dir, 'read.svg');
  fs.writeFileSync(file, SVG);
  const result = await client.callTool({ name: 'read_file', arguments: { path: file } });
  assert(!result.content?.some((block) => block.type === 'image'),
    `read_file of a text .svg answered an image block instead of its text (blocks: ${blockTypes(result)})`);
  assert(textOf(result).includes(SVG), `read_file of a text .svg did not answer its text: ${textOf(result).slice(0, 200)}`);
}

async function readMultipleFilesAnswersTheText(client, dir) {
  const file = path.join(dir, 'multi.svg');
  fs.writeFileSync(file, SVG);
  const result = await client.callTool({ name: 'read_multiple_files', arguments: { paths: [file] } });
  assert(!result.content?.some((block) => block.type === 'image'),
    `read_multiple_files of a text .svg answered an image block instead of its text (blocks: ${blockTypes(result)})`);
  assert(textOf(result).includes(SVG), `read_multiple_files of a text .svg did not answer its text: ${textOf(result).slice(0, 200)}`);
}

async function writeFileWritesTheText(client, dir) {
  const file = path.join(dir, 'write.svg');
  const result = await client.callTool({ name: 'write_file', arguments: { path: file, content: SVG, mode: 'rewrite' } });
  const written = fs.existsSync(file) ? fs.readFileSync(file) : Buffer.alloc(0);
  assert.strictEqual(written.toString('utf8'), SVG,
    `write_file answered "${textOf(result).split('\n')[0]}", but the .svg holds ${written.length} bytes (${JSON.stringify(written.toString('latin1'))}) instead of the ${SVG.length} characters sent`);
}

async function editBlockWritesTheText(client, dir) {
  const file = path.join(dir, 'edit.svg');
  fs.writeFileSync(file, SVG);
  const result = await client.callTool({ name: 'edit_block', arguments: { file_path: file, old_string: '<rect', new_string: '<rect x="0"' } });
  const edited = fs.readFileSync(file);
  assert.strictEqual(edited.toString('utf8'), SVG.replace('<rect', '<rect x="0"'),
    `edit_block answered "${textOf(result).split('\n')[0]}", but the .svg holds ${edited.length} bytes (${JSON.stringify(edited.toString('latin1'))}) instead of the edited text`);
}

async function urlReadsAreDenied(client) {
  for (const url of ['http://127.0.0.1:9/icon.svg', 'http://127.0.0.1:9/icon.png']) {
    const result = await client.callTool({ name: 'read_file', arguments: { path: url, isUrl: true } });
    assert(result.isError === true && /URL reads are disabled by DeskPilot policy/.test(textOf(result)),
      `${url} must be denied before any fetch; got ${textOf(result)}`);
  }
}

async function previewWidgetStillGetsTheImage(client, dir) {
  const file = path.join(dir, 'preview.svg');
  fs.writeFileSync(file, SVG);
  const result = await client.callTool({ name: 'read_file', arguments: { path: file, origin: 'ui' } });
  assert.strictEqual(result.structuredContent?.fileType, 'image', `the preview widget's read of an .svg should draw it as an image, got fileType ${result.structuredContent?.fileType}`);
  assert.strictEqual(result.structuredContent?.mimeType, 'image/svg+xml', `the preview widget's read of an .svg should say image/svg+xml, got ${result.structuredContent?.mimeType}`);
  assert.strictEqual(textOf(result), Buffer.from(SVG).toString('base64'), `the preview widget's read of an .svg should carry the file as base64, got ${textOf(result).slice(0, 200)}`);
}

export default async function runTests() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dc-svg-text-'));
  let client;
  const failures = [];
  try {
    client = await connectToServer('svg-text-test');
    for (const check of [readFileAnswersTheText, readMultipleFilesAnswersTheText, writeFileWritesTheText, editBlockWritesTheText, previewWidgetStillGetsTheImage,
      urlReadsAreDenied]) {
      try {
        await check(client, dir);
        console.log(`✓ ${check.name}`);
      } catch (error) {
        failures.push(error);
        console.error(`✗ ${check.name}: ${error.message}`);
      }
    }
  } finally {
    await closeClient(client);
    fs.rmSync(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  }
  assert.deepStrictEqual(failures.map((error) => error.message), [], `${failures.length} check(s) failed`);
  return true;
}

runIfMain(import.meta.url, runTests);
