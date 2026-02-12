#!/usr/bin/env node
'use strict'

// mixed-bench.js — Run a mixed workload benchmark via autocannon programmatic API
// Usage: node mixed-bench.js <url> <connections> <pipelining> <duration> <output_file>
//
// Distribution: 70% GET single, 10% GET list, 10% POST, 5% PUT, 5% DELETE
// All POST/PUT bodies use unique emails per request via setupRequest callbacks.
// GET single and DELETE target random IDs in the seeded 1-10000 range per request.

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
let postCounter = 0
let putCounter = 0

// Build a GET-single request with a random path per invocation
function getSingleRequest () {
  return {
    method: 'GET',
    path: '/users/' + rid(),
    setupRequest: (req) => {
      req.path = '/users/' + rid()
      return req
    }
  }
}

// Build a GET-list request (pages 1-10, randomly chosen per request)
function getListRequest (page) {
  return {
    method: 'GET',
    path: '/users?page=' + page + '&limit=20'
  }
}

// Build a POST request with unique email per invocation
function postRequest () {
  return {
    method: 'POST',
    path: '/users',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: 'Mix User', email: 'placeholder@test.com', bio: 'mixed bench' }),
    setupRequest: (req) => {
      const id = ++postCounter
      req.body = JSON.stringify({
        name: 'Mix User',
        email: `mix_${Date.now()}_${id}@test.com`,
        bio: 'mixed bench'
      })
      return req
    }
  }
}

// Build a PUT request with random target ID and unique email per invocation
function putRequest () {
  return {
    method: 'PUT',
    path: '/users/' + rid(),
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: 'Updated User', email: 'placeholder@test.com', bio: 'updated' }),
    setupRequest: (req) => {
      const id = ++putCounter
      req.path = '/users/' + rid()
      req.body = JSON.stringify({
        name: 'Updated User',
        email: `updated_${Date.now()}_${id}@test.com`,
        bio: 'updated'
      })
      return req
    }
  }
}

// Build a DELETE request with random target ID per invocation
function deleteRequest () {
  return {
    method: 'DELETE',
    path: '/users/' + rid(),
    setupRequest: (req) => {
      req.path = '/users/' + rid()
      return req
    }
  }
}

// 20-element request array: 14 GET-single (70%), 2 GET-list (10%),
// 2 POST (10%), 1 PUT (5%), 1 DELETE (5%)
const requests = [
  // 14x GET single (70%)
  ...Array.from({ length: 14 }, () => getSingleRequest()),
  // 2x GET list (10%)
  getListRequest(1),
  getListRequest(2),
  // 2x POST (10%)
  postRequest(),
  postRequest(),
  // 1x PUT (5%)
  putRequest(),
  // 1x DELETE (5%)
  deleteRequest()
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
