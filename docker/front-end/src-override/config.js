(function (){
  'use strict';

  var session      = require("express-session"),
      RedisStore   = require('connect-redis')(session)

  // sameSite: 'lax' costs nothing (no HTTPS requirement, unlike `secure`,
  // which would break the cookie entirely behind this cluster's
  // edge-terminated route / port-forward setup where the app itself only
  // ever sees plain HTTP) but blocks the common cross-site request forgery
  // case of a third-party site auto-submitting a form against this app.
  var cookieOptions = { sameSite: 'lax' };

  module.exports = {
    session: {
      name: 'md.sid',
      secret: process.env.SESSION_SECRET || 'sooper secret',
      resave: false,
      saveUninitialized: true,
      cookie: cookieOptions
    },

    session_redis: {
      store: new RedisStore({host: "session-db"}),
      name: 'md.sid',
      secret: process.env.SESSION_SECRET || 'sooper secret',
      resave: false,
      saveUninitialized: true,
      cookie: cookieOptions
    }
  };
}());
