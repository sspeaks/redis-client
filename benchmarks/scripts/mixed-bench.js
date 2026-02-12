#!/usr/bin/env node
'use strict'

// mixed-bench.js — Run a mixed workload benchmark via autocannon programmatic API
// Usage: node mixed-bench.js <url> <connections> <pipelining> <duration> <output_file>

const autocannon = require('autocannon')
const fs = require('fs')

const url = process.argv[2]
const connections = parseInt(process.argv[3], 10)
const pipelining = parseInt(process.argv[4], 10)
const duration = parseInt(process.argv[5], 10)
const outputFile = process.argv[6]

if (!url || !outputFile) {
  console.error('Usage: node mixed-bench.js <url> <connections> <pipelining> <duration> <output_file>')
  process.exit(1)
}

const rid = () => Math.floor(Math.random() * 10000) + 1
const ts = Date.now()

// 20-element request array: 14 GET-single (70%), 2 GET-list (10%),
// 2 POST (10%), 1 PUT (5%), 1 DELETE (5%)
const requests = [
  // 14x GET single (70%)
  ...Array.from({ length: 14 }, () => ({ method: 'GET', path: '/users/' + rid() })),
  // 2x GET list (10%)
  { method: 'GET', path: '/users?page=1&limit=20' },
  { method: 'GET', path: '/users?page=2&limit=20' },
  // 2x POST (10%)
  { method: 'POST', path: '/users', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: 'Mix User', email: 'mix_' + ts + '_1@test.com', bio: 'mixed bench' }) },
  { method: 'POST', path: '/users', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: 'Mix User', email: 'mix_' + ts + '_2@test.com', bio: 'mixed bench' }) },
  // 1x PUT (5%)
  { method: 'PUT', path: '/users/' + rid(), headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: 'Updated User', email: 'updated_' + ts + '@test.com', bio: 'updated' }) },
  // 1x DELETE (5%)
  { method: 'DELETE', path: '/users/' + rid() }
]

const instance = autocannon({
  url,
  connections,
  pipelining,
  duration,
  requests
}, (err, result) => {
  if (err) {
    console.error('Benchmark error:', err)
    process.exit(1)
  }
  fs.writeFileSync(outputFile, JSON.stringify(result, null, 2))
  console.log('Mixed benchmark complete. Results saved to', outputFile)
})

autocannon.track(instance, { renderStatusCodes: true })
