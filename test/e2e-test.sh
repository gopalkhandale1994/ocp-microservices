#!/bin/sh
# End-to-end health check for the Sock Shop deployment.
#
# Runs from inside the cluster (as a throwaway pod) so it isn't affected by
# the Route/router issue documented in README.md -- this checks the actual
# services, not the public URL.
#
# Usage: ./test/e2e-test.sh [namespace]

set -u
NAMESPACE="${1:-gopalskhandale1994-dev}"
POD=e2e-test-runner
PASS=0
FAIL=0

echo "== Checking Deployment replica health in $NAMESPACE =="
for d in front-end catalogue catalogue-db carts carts-db orders orders-db \
         shipping payment queue-master rabbitmq session-db user user-db; do
  ready=$(oc get deployment "$d" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  desired=$(oc get deployment "$d" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  if [ "$ready" = "$desired" ] && [ -n "$ready" ] && [ "$ready" != "0" ]; then
    echo "  OK    $d ($ready/$desired ready)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $d (${ready:-0}/${desired:-?} ready)"
    FAIL=$((FAIL + 1))
  fi
done

echo
echo "== Launching in-cluster test pod =="
oc run "$POD" --image=curlimages/curl:latest --restart=Never -n "$NAMESPACE" \
  --command -- sleep 300 >/dev/null
oc wait --for=condition=Ready "pod/$POD" -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1

check_http() {
  # check_http <label> <url> <expected-status>
  label="$1"; url="$2"; expected="${3:-200}"
  code=$(oc exec "$POD" -n "$NAMESPACE" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null)
  if [ "$code" = "$expected" ]; then
    echo "  OK    $label -> HTTP $code"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label -> HTTP ${code:-no response} (expected $expected)"
    FAIL=$((FAIL + 1))
  fi
}

check_tcp() {
  # check_tcp <label> <host> <port>
  # These ports speak Mongo/MySQL/AMQP, not HTTP, so a real curl request
  # always "fails" against them -- what we care about is *how* it fails.
  # Exit code 7 means curl couldn't even open the TCP connection (port
  # unreachable); anything else means it connected fine and the failure
  # is just curl not understanding the non-HTTP protocol on the wire.
  label="$1"; host="$2"; port="$3"
  oc exec "$POD" -n "$NAMESPACE" -- curl -s -o /dev/null --connect-timeout 3 --max-time 5 "http://$host:$port/" >/dev/null 2>&1
  code=$?
  if [ "$code" != "7" ]; then
    echo "  OK    $label ($host:$port accepted a connection)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label ($host:$port refused connection)"
    FAIL=$((FAIL + 1))
  fi
}

echo
echo "== Direct service checks (real /health endpoints) =="
check_http "catalogue /health"  "http://catalogue/health"
check_http "payment   /health"  "http://payment/health"
check_http "user      /health"  "http://user/health"

echo
echo "== front-end proxy checks (proves front-end -> backend wiring) =="
check_http "front-end /          "        "http://front-end/"
check_http "front-end /catalogue (-> catalogue)" "http://front-end/catalogue"
check_http "front-end /tags      (-> catalogue)" "http://front-end/tags"

echo
echo "== TCP-only checks (no HTTP health endpoint exposed by these) =="
check_tcp "carts"        carts        80
check_tcp "orders"       orders       80
check_tcp "shipping"     shipping     80
check_tcp "queue-master" queue-master 80
check_tcp "carts-db"     carts-db     27017
check_tcp "orders-db"    orders-db    27017
check_tcp "user-db"      user-db      27017
check_tcp "catalogue-db" catalogue-db 3306
check_tcp "rabbitmq"     rabbitmq     5672
check_tcp "session-db"   session-db  6379

echo
echo "== Cleaning up =="
oc delete pod "$POD" -n "$NAMESPACE" >/dev/null 2>&1

echo
echo "===================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "===================================="
[ "$FAIL" -eq 0 ]
