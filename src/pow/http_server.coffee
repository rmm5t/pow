fs          = require "fs"
sys         = require "sys"
connect     = require "connect"
{pause}     = require "./util"
RackHandler = require "./rack_handler"

{dirname, join}  = require "path"

getHost = (req) ->
  req.headers.host.replace /:.*/, ""

escapeHTML = (string) ->
  string.toString()
    .replace(/&/g,  "&amp;")
    .replace(/</g,  "&lt;")
    .replace(/>/g,  "&gt;")
    .replace(/\"/g, "&quot;")

# Connect depends on Function.prototype.length to determine
# whether a given middleware is an error handler. These wrappers
# provide compatibility with bound instance methods.
o = (fn) -> (req, res, next)      -> fn req, res, next
x = (fn) -> (err, req, res, next) -> fn err, req, res, next

module.exports = class HttpServer extends connect.HTTPServer
  constructor: (@configuration) ->
    super [
      o @logRequest
      o @handleRackRequest
      x @handleApplicationException
      o @handleNonexistentDomain
    ]
    @rackHandlers   = {}
    @staticHandlers = {}
    @accessLog = @configuration.getLogger "access"
    @on "close", @closeApplications

  getRackHandlerForHost: (host, callback) ->
    @configuration.findApplicationRootForHost host, (err, root) =>
      return callback err if err
      @getRackHandlerForRoot root, callback

  getRackHandlerForRoot: (root, callback) ->
    if not root
      callback()
    else if handler = @rackHandlers[root]
      callback null, handler
    else
      @rackHandlers[root] = new RackHandler @configuration, root, callback

  closeApplications: =>
    for root, handler of @rackHandlers
      handler.quit()

  logRequest: (req, res, next) =>
    @accessLog.info "[#{req.socket.remoteAddress}] #{req.method} #{req.headers.host} #{req.url}"
    next()

  handleRackRequest: (req, res, next) =>
    host    = getHost req
    resume  = pause req
    req.pow = {host}

    @getRackHandlerForHost host, (err, handler) =>
      req.pow.handler = handler

      if handler
        if err
          next err
          resume()
        else
          handler.handle req, res, next, resume
      else
        @handleNonexistentDomain req, res, next
        resume()

  handleApplicationException: (err, req, res, next) =>
    return next() unless req.pow?.handler

    res.writeHead 500, "Content-Type": "text/html; charset=utf8", "X-Pow-Handler": "ApplicationException"
    res.end """
      <!doctype html>
      <html>
      <head>
        <title>Pow: Error Starting Application</title>
        <style>
          body {
            margin: 0;
            padding: 0;
          }
          h1, h2, pre {
            margin: 0;
            padding: 15px 30px;
          }
          h1, h2 {
            font-family: Helvetica, sans-serif;
          }
          h1 {
            font-size: 36px;
            background: #eeedea;
            color: #c00;
            border-bottom: 1px solid #999090;
          }
          h2 {
            font-size: 18px;
            font-weight: normal;
          }
        </style>
      </head>
      <body>
        <h1>Pow can&rsquo;t start your application.</h1>
        <h2><code>#{escapeHTML req.pow.handler.root}</code> raised an exception during boot.</h2>
        <pre><strong>#{escapeHTML err}</strong>#{escapeHTML "\n" + err.stack}</pre>
      </body>
      </html>
    """

  handleNonexistentDomain: (req, res, next) =>
    return next() unless req.pow
    host = req.pow.host
    name = host.slice 0, host.length - @configuration.domain.length - 1
    path = join @configuration.root, name

    res.writeHead 503, "Content-Type": "text/html; charset=utf8", "X-Pow-Handler": "NonexistentDomain"
    res.end """
      <!doctype html>
      <html>
      <head>
        <title>Pow: No Such Application</title>
        <style>
          body {
            margin: 0;
            padding: 0;
          }
          h1, h2 {
            margin: 0;
            padding: 15px 30px;
            font-family: Helvetica, sans-serif;
          }
          h1 {
            font-size: 36px;
            background: #eeedea;
            color: #000;
            border-bottom: 1px solid #999090;
          }
          h2 {
            font-size: 18px;
            font-weight: normal;
          }
        </style>
      </head>
      <body>
        <h1>This domain isn&rsquo;t set up yet.</h1>
        <h2>Symlink your application to <code>#{escapeHTML path}</code> first.</h2>
      </body>
      </html>
    """
