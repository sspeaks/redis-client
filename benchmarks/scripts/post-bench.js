#!/usr/bin/env node
'use strict'

// post-bench.js — Run a POST benchmark with unique emails via autocannon programmatic API
// Usage: node post-bench.js <url> <connections> <pipelining> <duration> <output_file>

const autocannon = require('autocannon')
const fs = require('fs')

const url = process.argv[2]
const connections = parseInt(process.argv[3], 10)
const pipelining = parseInt(process.argv[4], 10)
const duration = parseInt(process.argv[5], 10)
const outputFile = process.argv[6]

if (!url || !outputFile) {
  console.error('Usage: node post-bench.js <url> <connections> <pipelining> <duration> <output_file>')
  process.exit(1)
}

let counter = 0

const instance = autocannon({
  url,
  connections,
  pipelining,
  duration,
  requests: [
    {
      method: 'POST',
      path: '/users',
      headers: { 'Content-Type': 'application/json' },
      setupRequest: (req, context) => {
        const id = ++counter
        req.body = JSON.stringify({
          name: 'Bench User',
          email: `bench_${Date.now()}_${id}@test.com`,
          bio: 'created by benchmark'
        })
        return req
      }
    }
  ]
}, (err, result) => {
  if (err) {
    console.error('Benchmark error:', err)
    process.exit(1)
  }
  fs.writeFileSync(outputFile, JSON.stringify(result, null, 2))
  console.log('POST benchmark complete. Results saved to', outputFile)
})

autocannon.track(instance, { renderStatusCodes: true })
