(function (){
  'use strict';

  var async     = require("async")
    , express   = require("express")
    , request   = require("request")
    , endpoints = require("../endpoints")
    , helpers   = require("../../helpers")
    , app       = express()

  app.get("/orders", function (req, res, next) {
    console.log("Request received with body: " + JSON.stringify(req.body));
    var logged_in = req.cookies.logged_in;
    if (!logged_in) {
      throw new Error("User not logged in.");
      return
    }

    var custId = req.session.customerId;
    async.waterfall([
        function (callback) {
          request(endpoints.ordersUrl + "/orders/search/customerId?sort=date&custId=" + custId, function (error, response, body) {
            if (error) {
              return callback(error);
            }
            console.log("Received response: " + JSON.stringify(body));
            if (response.statusCode == 404) {
              console.log("No orders found for user: " + custId);
              return callback(null, []);
            }
            callback(null, JSON.parse(body)._embedded.customerOrders);
          });
        }
    ],
    function (err, result) {
      if (err) {
        return next(err);
      }
      helpers.respondStatusBody(res, 201, JSON.stringify(result));
    });
  });

  app.get("/orders/*", function (req, res, next) {
    var url = endpoints.ordersUrl + req.url.toString();
    request.get(url).pipe(res);
  });

  app.post("/orders", function(req, res, next) {
    console.log("Request received with body: " + JSON.stringify(req.body));
    var logged_in = req.cookies.logged_in;
    if (!logged_in) {
      throw new Error("User not logged in.");
      return
    }

    var custId = req.session.customerId;

    async.waterfall([
        function (callback) {
          request(endpoints.customersUrl + "/" + custId, function (error, response, body) {
            if (error) {
              callback(error);
              return;
            }
            console.log("Received response: " + JSON.stringify(body));
            // BUGFIX: the original code checked `body.status_code === 500`
            // here, but `body` at this point is still the raw response
            // *string* -- strings don't have a status_code property, so
            // that check was always false (dead code) and every error
            // response (which has no _links at all, e.g.
            // {"error":"...","status_code":500}) fell through to
            // `jsonBody._links.customer.href` below and threw a
            // TypeError that crashed the whole Node process (no per-request
            // isolation), taking front-end down for every user, not just
            // this request. Parse first, then check the parsed shape.
            var jsonBody;
            try {
              jsonBody = JSON.parse(body);
            } catch (e) {
              callback(new Error("Could not parse customer response: " + body));
              return;
            }
            if (!jsonBody || !jsonBody._links || jsonBody.status_code === 500) {
              callback(new Error("Customer lookup failed for id " + custId + ": " + body));
              return;
            }
            var customerlink = jsonBody._links.customer.href;
            var addressLink = jsonBody._links.addresses.href;
            var cardLink = jsonBody._links.cards.href;
            var order = {
              "customer": customerlink,
              "address": null,
              "card": null,
              "items": endpoints.cartsUrl + "/" + custId + "/items"
            };
            callback(null, order, addressLink, cardLink);
          });
        },
        function (order, addressLink, cardLink, callback) {
          async.parallel([
              function (callback) {
                console.log("GET Request to: " + addressLink);
                request.get(addressLink, function (error, response, body) {
                  if (error) {
                    callback(error);
                    return;
                  }
                  console.log("Received response: " + JSON.stringify(body));
                  var jsonBody = JSON.parse(body);
                  // Same class of bug as above: guard _embedded's presence
                  // before indexing into it (an account with no address yet
                  // has no _embedded at all, not an empty one).
                  if (jsonBody.status_code !== 500 && jsonBody._embedded && jsonBody._embedded.address && jsonBody._embedded.address[0] != null) {
                    order.address = jsonBody._embedded.address[0]._links.self.href;
                  }
                  callback();
                });
              },
              function (callback) {
                console.log("GET Request to: " + cardLink);
                request.get(cardLink, function (error, response, body) {
                  if (error) {
                    callback(error);
                    return;
                  }
                  console.log("Received response: " + JSON.stringify(body));
                  var jsonBody = JSON.parse(body);
                  if (jsonBody.status_code !== 500 && jsonBody._embedded && jsonBody._embedded.card && jsonBody._embedded.card[0] != null) {
                    order.card = jsonBody._embedded.card[0]._links.self.href;
                  }
                  callback();
                });
              }
          ], function (err, result) {
            if (err) {
              callback(err);
              return;
            }
            console.log(result);
            callback(null, order);
          });
        },
        function (order, callback) {
          var options = {
            uri: endpoints.ordersUrl + '/orders',
            method: 'POST',
            json: true,
            body: order
          };
          console.log("Posting Order: " + JSON.stringify(order));
          request(options, function (error, response, body) {
            if (error) {
              return callback(error);
            }
            console.log("Order response: " + JSON.stringify(response));
            console.log("Order response: " + JSON.stringify(body));
            callback(null, response.statusCode, body);
          });
        }
    ],
    function (err, status, result) {
      if (err) {
        return next(err);
      }
      helpers.respondStatusBody(res, status, JSON.stringify(result));
    });
  });

  module.exports = app;
}());
