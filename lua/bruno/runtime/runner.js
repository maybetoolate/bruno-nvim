#!/usr/bin/env node
/*
 * Sandbox host for Bruno request scripts.
 *
 * Usage: node runner.js <context.json> <result.json>
 *
 * The context carries the scripts for one lifecycle phase plus the current
 * variables and request/response data. The result file receives variable
 * updates, request mutations, test results and captured console output.
 */
'use strict'

const fs = require('fs')
const path = require('path')

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

function makeExpect(actual, negated) {
  const prefix = negated ? 'not ' : ''
  const fail = (message) => {
    throw new Error(prefix + message)
  }
  const assert = (condition, message) => {
    if (negated ? condition : !condition) {
      fail(message)
    }
  }

  const api = {}
  const passthrough = ['to', 'be', 'been', 'is', 'that', 'which', 'and', 'has', 'have', 'with', 'at', 'of', 'same', 'but', 'does', 'still', 'also']
  for (const key of passthrough) {
    api[key] = api
  }
  Object.defineProperty(api, 'not', {
    get() {
      return makeExpect(actual, !negated)
    },
  })

  api.equal = (expected) => assert(actual === expected, `expected ${JSON.stringify(actual)} to equal ${JSON.stringify(expected)}`)
  api.equals = api.equal
  api.eq = api.equal
  api.eql = (expected) => {
    try {
      assert(JSON.stringify(actual) === JSON.stringify(expected), `expected ${JSON.stringify(actual)} to deeply equal ${JSON.stringify(expected)}`)
    } catch (error) {
      if (error instanceof TypeError) {
        assert(actual === expected, `expected ${JSON.stringify(actual)} to deeply equal ${JSON.stringify(expected)}`)
      } else {
        throw error
      }
    }
  }
  api.above = (n) => assert(actual > n, `expected ${actual} to be above ${n}`)
  api.greaterThan = api.above
  api.below = (n) => assert(actual < n, `expected ${actual} to be below ${n}`)
  api.lessThan = api.below
  api.least = (n) => assert(actual >= n, `expected ${actual} to be at least ${n}`)
  api.most = (n) => assert(actual <= n, `expected ${actual} to be at most ${n}`)
  api.within = (min, max) => assert(actual >= min && actual <= max, `expected ${actual} to be within ${min}..${max}`)
  api.include = (needle) => {
    if (typeof actual === 'string') {
      assert(actual.includes(needle), `expected string to include ${JSON.stringify(needle)}`)
    } else if (Array.isArray(actual)) {
      assert(actual.includes(needle), `expected array to include ${JSON.stringify(needle)}`)
    } else {
      assert(false, 'include expects a string or array')
    }
  }
  api.contains = api.include
  api.contain = api.include
  api.match = (re) => assert(new RegExp(re).test(String(actual)), `expected ${actual} to match ${re}`)
  api.a = (type) => {
    const actualType = actual === null ? 'null' : Array.isArray(actual) ? 'array' : typeof actual
    const expected = String(type).toLowerCase()
    assert(actualType === expected, `expected ${JSON.stringify(actual)} to be a ${expected}`)
  }
  api.an = api.a
  api.lengthOf = (n) => assert(actual != null && actual.length === n, `expected length ${n}`)
  api.property = (name, value) => {
    const present = actual != null && name in Object(actual)
    if (value === undefined) {
      assert(present, `expected property ${name}`)
    } else {
      assert(present && actual[name] === value, `expected property ${name} to equal ${JSON.stringify(value)}`)
    }
  }
  api.keys = (keys) => {
    const actualKeys = Object.keys(Object(actual))
    for (const key of keys) {
      assert(actualKeys.includes(key), `expected keys to include ${key}`)
    }
  }
  api.status = (code) => assert(actual === code, `expected status ${code} but got ${actual}`)

  Object.defineProperty(api, 'ok', { get: () => { assert(!!actual, 'expected value to be truthy'); return api } })
  Object.defineProperty(api, 'true', { get: () => { assert(actual === true, 'expected true'); return api } })
  Object.defineProperty(api, 'false', { get: () => { assert(actual === false, 'expected false'); return api } })
  Object.defineProperty(api, 'null', { get: () => { assert(actual === null, 'expected null'); return api } })
  Object.defineProperty(api, 'undefined', { get: () => { assert(actual === undefined, 'expected undefined'); return api } })
  Object.defineProperty(api, 'empty', {
    get: () => {
      const empty = actual == null || actual.length === 0 || (typeof actual === 'object' && Object.keys(actual).length === 0)
      assert(empty, 'expected an empty value')
      return api
    },
  })
  Object.defineProperty(api, 'exist', { get: () => { assert(actual != null, 'expected value to exist'); return api } })

  return api
}

function parseBody(body, contentType) {
  if (typeof body !== 'string' || body === '') {
    return body
  }
  if ((contentType || '').includes('json') || /^\s*[\[{]/.test(body)) {
    try {
      return JSON.parse(body)
    } catch (_) {
      return body
    }
  }
  return body
}

function loadContext(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'))
}

async function main() {
  const contextFile = process.argv[2]
  const resultFile = process.argv[3]
  if (!contextFile || !resultFile) {
    throw new Error('usage: runner.js <context.json> <result.json>')
  }

  const context = loadContext(contextFile)
  const asObject = (value) => (value && typeof value === 'object' && !Array.isArray(value) ? value : {})
  const result = {
    ok: true,
    error: null,
    vars: asObject(context.vars),
    envVars: asObject(context.envVars),
    collectionVars: asObject(context.collectionVars),
    request: context.request || {},
    tests: [],
    logs: [],
    nextRequest: null,
    deletedVars: [],
    secrets: context.secrets || [],
  }
  result.request.headers = asObject(result.request.headers)

  const tests = result.tests
  const logs = result.logs
  const pendingTests = []
  const envVarChanges = {}
  let currentTest = null
  const deletedVars = []

  const consoleProxy = {
    log: (...args) => logs.push({ level: 'log', message: args.map(formatLog).join(' ') }),
    info: (...args) => logs.push({ level: 'info', message: args.map(formatLog).join(' ') }),
    warn: (...args) => logs.push({ level: 'warn', message: args.map(formatLog).join(' ') }),
    error: (...args) => logs.push({ level: 'error', message: args.map(formatLog).join(' ') }),
    debug: (...args) => logs.push({ level: 'debug', message: args.map(formatLog).join(' ') }),
  }

  function formatLog(value) {
    if (typeof value === 'string') return value
    try {
      return JSON.stringify(value)
    } catch (_) {
      return String(value)
    }
  }

  const bru = {
    setVar: (name, value) => {
      result.vars[name] = value
      const i = deletedVars.indexOf(name)
      if (i >= 0) deletedVars.splice(i, 1)
    },
    getVar: (name) => result.vars[name],
    deleteVar: (name) => {
      delete result.vars[name]
      if (!deletedVars.includes(name)) deletedVars.push(name)
    },
    setEnvVar: (name, value) => { result.envVars[name] = value; envVarChanges[name] = value },
    getEnvVar: (name) => result.envVars[name],
    deleteEnvVar: (name) => { delete result.envVars[name]; envVarChanges[name] = null },
    setCollectionVar: (name, value) => { result.collectionVars[name] = value },
    getCollectionVar: (name) => result.collectionVars[name],
    setNextRequest: (name) => { result.nextRequest = name },
    getNextRequest: () => result.nextRequest,
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    getSecretVar: () => {
      throw new Error('secret variables are not available to scripts in bruno-nvim')
    },
    interpolate: (value) => value,
  }

  const req = {
    url: result.request.url,
    method: result.request.method,
    headers: result.request.headers || {},
    body: result.request.body,
    setUrl(value) { result.request.url = value; this.url = value },
    getUrl() { return result.request.url },
    setMethod(value) { result.request.method = value; this.method = value },
    getMethod() { return result.request.method },
    setHeader(name, value) { result.request.headers[name] = value; this.headers = result.request.headers },
    getHeader(name) { return result.request.headers[name] },
    getHeaders() { return result.request.headers },
    setHeaders(headers) {
      result.request.headers = asObject(headers)
      this.headers = result.request.headers
    },
    deleteHeader(name) { delete result.request.headers[name]; this.headers = result.request.headers },
    setBody(value) { result.request.body = value; this.body = value },
    getBody() { return result.request.body },
    disableHeader(name) { delete result.request.headers[name]; this.headers = result.request.headers },
  }

  const response = context.response
  const responseHeaders = response ? asObject(response.headers) : {}
  const responseBody = response ? parseBody(response.body, response.contentType) : undefined
  const res = response
    ? {
        status: response.status,
        statusText: response.statusText || response.reason || '',
        headers: responseHeaders,
        body: responseBody,
        responseTime: response.responseTime || 0,
        size: response.size || 0,
        url: response.url || '',
        // Bruno's object accessors, as used by existing collection scripts.
        getStatus() {
          return this.status
        },
        getStatusText() {
          return this.statusText
        },
        getHeaders() {
          return this.headers
        },
        getHeader(name) {
          const key = String(name).toLowerCase()
          for (const header of Object.keys(this.headers)) {
            if (header.toLowerCase() === key) return this.headers[header]
          }
          return undefined
        },
        getBody() {
          return this.body
        },
        getResponseTime() {
          return this.responseTime
        },
        getSize() {
          return this.size
        },
        getUrl() {
          return this.url
        },
      }
    : {}

  function test(name, fn) {
    const entry = { name: name || 'test', passed: true, error: null }
    currentTest = entry
    try {
      const value = fn()
      if (value && typeof value.then === 'function') {
        const pendingTest = value.then(
          () => { tests.push(entry) },
          (error) => {
            entry.passed = false
            entry.error = error && error.message ? error.message : String(error)
            tests.push(entry)
          }
        )
        pendingTests.push(pendingTest)
        return pendingTest
      }
      tests.push(entry)
    } catch (error) {
      entry.passed = false
      entry.error = error && error.message ? error.message : String(error)
      tests.push(entry)
    } finally {
      currentTest = null
    }
    return undefined
  }

  const sandbox = {
    bru,
    req,
    res,
    expect: (actual) => makeExpect(actual, false),
    test,
    console: consoleProxy,
    require,
    process: { env: process.env, platform: process.platform, version: process.version },
    Buffer,
    URL,
    URLSearchParams,
    setTimeout,
    clearTimeout,
    atob: (value) => Buffer.from(value, 'base64').toString('binary'),
    btoa: (value) => Buffer.from(value, 'binary').toString('base64'),
  }

  const keys = Object.keys(sandbox)
  const values = keys.map((key) => sandbox[key])

  for (const script of context.scripts || []) {
    const label = script.name || script.type || 'script'
    try {
      const fn = new AsyncFunction(...keys, script.code)
      await fn(...values)
      if (pendingTests.length > 0) {
        await Promise.all(pendingTests.splice(0))
      }
    } catch (error) {
      const message = error && error.stack ? error.stack : String(error)
      if (currentTest) {
        currentTest.passed = false
        currentTest.error = message
      } else {
        tests.push({ name: `${label} (script error)`, passed: false, error: message })
      }
      result.ok = false
      result.error = message
      break
    }
  }

  result.request = req
  result.envVars = envVarChanges
  result.deletedVars = deletedVars
  fs.writeFileSync(resultFile, JSON.stringify(result), 'utf8')
}

main().catch((error) => {
  const resultFile = process.argv[3]
  const payload = {
    ok: false,
    error: error && error.stack ? error.stack : String(error),
    vars: {},
    envVars: {},
    collectionVars: {},
    request: {},
    tests: [],
    logs: [],
  }
  try {
    fs.writeFileSync(resultFile, JSON.stringify(payload), 'utf8')
  } catch (_) {
    process.stderr.write(String(payload.error))
  }
  process.exitCode = 1
})
