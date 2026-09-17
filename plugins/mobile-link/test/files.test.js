import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, existsSync, rmSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { FileInbox, FILE_BEGIN, FILE_CHUNK, FILE_END, isFileMethod } from '../lib/files.js'

const sessionId = `test-${process.pid}`
const directory = join(homedir(), '.dsh', 'inbox', sessionId)

function cleanup() {
  rmSync(directory, { recursive: true, force: true })
}

/** Splits a buffer the way the phone does. */
function chunksOf(buffer, size) {
  const parts = []
  for (let offset = 0; offset < buffer.length; offset += size) {
    parts.push(buffer.subarray(offset, offset + size))
  }
  return parts
}

test('isFileMethod claims only the reserved names', () => {
  assert.ok(isFileMethod(FILE_BEGIN))
  assert.ok(isFileMethod(FILE_CHUNK))
  assert.ok(isFileMethod(FILE_END))
  // Everything else must keep going to the Host as an ordinary RPC.
  assert.equal(isFileMethod('session/list'), false)
  assert.equal(isFileMethod('_link/other'), false)
})

test('a chunked transfer lands byte-for-byte', () => {
  cleanup()
  const inbox = new FileInbox({})
  // Deliberately not text: binary is where an encoding mistake shows up.
  const body = Buffer.from(Array.from({ length: 5000 }, (_, i) => (i * 7) % 256))

  inbox.handle(FILE_BEGIN, { transferId: 't1', sessionId, name: 'report.pdf', bytes: body.length })
  chunksOf(body, 1024).forEach((part, seq) => {
    inbox.handle(FILE_CHUNK, { transferId: 't1', seq, data: part.toString('base64') })
  })
  const done = inbox.handle(FILE_END, { transferId: 't1' })

  assert.equal(done.bytes, body.length)
  assert.equal(done.path, join(directory, 'report.pdf'))
  assert.ok(existsSync(done.path), 'the file was not written')
  assert.ok(readFileSync(done.path).equals(body), 'the bytes changed in transit')
  // Nothing half-written is left behind for the agent to trip over.
  assert.equal(existsSync(join(directory, '.report.pdf.part')), false)
  cleanup()
})

test('the final name only appears once the transfer completes', () => {
  cleanup()
  const inbox = new FileInbox({})
  inbox.handle(FILE_BEGIN, { transferId: 't2', sessionId, name: 'half.txt', bytes: 10 })
  inbox.handle(FILE_CHUNK, { transferId: 't2', seq: 0, data: Buffer.from('12345').toString('base64') })
  assert.equal(existsSync(join(directory, 'half.txt')), false, 'an incomplete file is visible')
  cleanup()
})

test('an out-of-order chunk is refused', () => {
  cleanup()
  const inbox = new FileInbox({})
  inbox.handle(FILE_BEGIN, { transferId: 't3', sessionId, name: 'x.bin', bytes: 8 })
  inbox.handle(FILE_CHUNK, { transferId: 't3', seq: 0, data: Buffer.from('abcd').toString('base64') })
  assert.throws(
    () => inbox.handle(FILE_CHUNK, { transferId: 't3', seq: 5, data: 'AAAA' }),
    /out of order/,
  )
  cleanup()
})

test('a size mismatch is refused rather than written', () => {
  cleanup()
  const inbox = new FileInbox({})
  inbox.handle(FILE_BEGIN, { transferId: 't4', sessionId, name: 'short.bin', bytes: 100 })
  inbox.handle(FILE_CHUNK, { transferId: 't4', seq: 0, data: Buffer.from('abc').toString('base64') })
  assert.throws(() => inbox.handle(FILE_END, { transferId: 't4' }), /expected 100 bytes/)
  assert.equal(existsSync(join(directory, 'short.bin')), false, 'a truncated file was kept')
  cleanup()
})

test('a chunk without a transfer is refused', () => {
  const inbox = new FileInbox({})
  assert.throws(() => inbox.handle(FILE_CHUNK, { transferId: 'nope', seq: 0, data: '' }), /unknown transfer/)
})

test('a transfer needs a session and an id', () => {
  const inbox = new FileInbox({})
  assert.throws(() => inbox.handle(FILE_BEGIN, { name: 'a' }), /transferId/)
  assert.throws(() => inbox.handle(FILE_BEGIN, { transferId: 't' }), /sessionId/)
})

test('clear drops in-flight transfers', () => {
  cleanup()
  const inbox = new FileInbox({})
  inbox.handle(FILE_BEGIN, { transferId: 't5', sessionId, name: 'gone.bin', bytes: 4 })
  inbox.handle(FILE_CHUNK, { transferId: 't5', seq: 0, data: Buffer.from('ab').toString('base64') })
  inbox.clear()
  assert.throws(() => inbox.handle(FILE_END, { transferId: 't5' }), /unknown transfer/)
  cleanup()
})
