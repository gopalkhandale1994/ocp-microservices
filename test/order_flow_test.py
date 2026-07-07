#!/usr/bin/env python3
"""
Register -> login -> add address/card -> add to cart -> place order.
Talks only to front-end, exactly as a browser would (session + cookies),
using the real request shapes read out of front-end's own source
(api/user, api/cart, api/orders, helpers/index.js) -- not guessed.

Exit code 0 iff every step passed. Prints the customerId at the end so
the caller can go verify the same data directly in orders-db/user-db.
"""
import base64
import http.cookiejar
import json
import os
import random
import string
import sys
import urllib.error
import urllib.request

# Deliberately NOT the short Service name "front-end": Python's
# http.cookiejar silently rewrites single-label hostnames (no dot) to
# "<host>.local" internally (an RFC 2965 "local domain" heuristic), then
# fails to match that against the plain hostname on the *next* request --
# so cookies never get sent back and every request after the first starts
# a brand-new anonymous session. Using the fully-qualified in-cluster DNS
# name (which has dots) sidesteps the quirk entirely.
NAMESPACE = os.environ.get("NAMESPACE", "gopalskhandale1994-dev")
BASE = f"http://front-end.{NAMESPACE}.svc.cluster.local"
TIMEOUT = 10

cj = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

results = []


def check(label, condition, detail=""):
    status = "OK  " if condition else "FAIL"
    print(f"  {status}  {label}  {detail}".rstrip())
    results.append(condition)
    return condition


def call(method, path, body=None, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        resp = opener.open(req, timeout=TIMEOUT)
        return resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except Exception as e:
        return None, str(e)


suffix = "".join(random.choices(string.ascii_lowercase + string.digits, k=8))
username = f"e2e_{suffix}"
password = "TestPass123!"
email = f"{username}@example.test"

print(f"== Test user: {username} ==\n")

# 1. Register
status, body = call("POST", "/register", {
    "username": username, "password": password, "email": email,
    "firstName": "E2E", "lastName": "Test",
})
ok = check("register", status == 200, f"-> HTTP {status}")
customer_id = None
if ok:
    try:
        customer_id = json.loads(body).get("id")
    except json.JSONDecodeError:
        pass
check("register returned a customerId", bool(customer_id), f"-> id={customer_id}")

# 2. Login (separately from register, to actually exercise the login path)
auth = base64.b64encode(f"{username}:{password}".encode()).decode()
status, body = call("GET", "/login", headers={"Authorization": f"Basic {auth}"})
check("login", status == 200, f"-> HTTP {status}")

# 3. Fetch a real catalogue item to order
status, body = call("GET", "/catalogue")
items = json.loads(body) if status == 200 else []
check("fetch catalogue", status == 200 and len(items) > 0, f"-> {len(items)} items")
item = items[0] if items else None
if item:
    print(f"        using item: {item.get('name')} ({item.get('id')}, ${item.get('price')})")

# 4. Address (required for order to attach a real address link)
status, body = call("POST", "/addresses", {
    "street": "1 Test Street", "number": "42", "city": "Testville",
    "postcode": "T35T 1NG", "country": "Testland",
})
check("add address", status == 200, f"-> HTTP {status}")

# 5. Card (required for order to attach a real card link)
status, body = call("POST", "/cards", {
    "longNum": "1234567890123456", "expires": "12/30", "ccv": "123",
})
check("add card", status == 200, f"-> HTTP {status}")

# 6. Add the item to cart
if item:
    status, body = call("POST", "/cart", {"id": item["id"]})
    check("add to cart", status == 201, f"-> HTTP {status}")

# 7. Confirm the cart actually has it
status, body = call("GET", "/cart")
cart_items = json.loads(body) if status == 200 else []
check("cart has item", status == 200 and len(cart_items) > 0, f"-> {len(cart_items)} item(s)")

# 8. Place the order
status, body = call("POST", "/orders")
placed = check("place order", status == 201, f"-> HTTP {status} {body[:200]}")
order_id = None
if placed:
    try:
        order_id = json.loads(body).get("id")
    except json.JSONDecodeError:
        pass

# 9. Confirm it shows back up via the API
status, body = call("GET", "/orders")
orders = json.loads(body) if status == 201 else []
check("order visible via GET /orders", status == 201 and len(orders) > 0, f"-> {len(orders)} order(s)")

print()
print(f"RESULT_CUSTOMER_ID={customer_id or ''}")
print(f"RESULT_ORDER_ID={order_id or ''}")
print(f"RESULT_USERNAME={username}")
print(f"SUMMARY: {sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
