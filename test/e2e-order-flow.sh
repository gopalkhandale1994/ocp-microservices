#!/bin/bash
# Full user-journey e2e test: register -> login -> add address/card ->
# add to cart -> place an order -- driven entirely through front-end, the
# same way a browser would -- and then verifies the resulting documents
# actually landed in orders-db and user-db, not just that the API said 200.
#
# Usage: ./test/e2e-order-flow.sh [namespace]

set -u
NAMESPACE="${1:-gopalskhandale1994-dev}"
RUNNER=e2e-order-flow-runner
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== Launching test runner pod =="
oc run "$RUNNER" --image=python:3-alpine --restart=Never -n "$NAMESPACE" \
  --command -- sleep 300 >/dev/null
if ! oc wait --for=condition=Ready "pod/$RUNNER" -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1; then
  echo "FAIL  runner pod never became ready"
  oc delete pod "$RUNNER" -n "$NAMESPACE" >/dev/null 2>&1
  exit 1
fi

oc cp "$SCRIPT_DIR/order_flow_test.py" "$NAMESPACE/$RUNNER:/tmp/order_flow_test.py" >/dev/null

echo
echo "== Running register -> login -> cart -> order flow against front-end =="
OUTPUT=$(oc exec "$RUNNER" -n "$NAMESPACE" -- env NAMESPACE="$NAMESPACE" python3 /tmp/order_flow_test.py 2>&1)
FLOW_STATUS=$?
echo "$OUTPUT"

CUSTOMER_ID=$(echo "$OUTPUT" | sed -n 's/^RESULT_CUSTOMER_ID=//p')
ORDER_ID=$(echo "$OUTPUT" | sed -n 's/^RESULT_ORDER_ID=//p')
USERNAME=$(echo "$OUTPUT" | sed -n 's/^RESULT_USERNAME=//p')

oc delete pod "$RUNNER" -n "$NAMESPACE" >/dev/null 2>&1

BACKEND_PASS=0
BACKEND_FAIL=0

echo
echo "== Verifying the new customer landed in user-db (not just the API response) =="
if [ -n "$USERNAME" ]; then
  USER_DB_POD=$(oc get pod -n "$NAMESPACE" -l app=user-db -o jsonpath='{.items[0].metadata.name}')
  RESULT=$(oc exec "$USER_DB_POD" -n "$NAMESPACE" -- mongo users --quiet \
    --eval "JSON.stringify(db.customers.findOne({username: \"$USERNAME\"}))" 2>&1)
  if echo "$RESULT" | grep -q "\"username\":\"$USERNAME\""; then
    echo "  OK    found customer '$USERNAME' in user-db: users.customers"
    BACKEND_PASS=$((BACKEND_PASS + 1))
  else
    echo "  FAIL  customer '$USERNAME' not found in user-db. Raw result:"
    echo "        $RESULT"
    BACKEND_FAIL=$((BACKEND_FAIL + 1))
  fi
else
  echo "  SKIP  no username captured from the flow test above (it must have failed earlier)"
  BACKEND_FAIL=$((BACKEND_FAIL + 1))
fi

echo
echo "== Verifying the new order landed in orders-db (not just the API response) =="
if [ -n "$ORDER_ID" ]; then
  ORDERS_DB_POD=$(oc get pod -n "$NAMESPACE" -l app=orders-db -o jsonpath='{.items[0].metadata.name}')
  # orders-db runs the same quay.io mongodb-community-server image as
  # user-db, which ships the legacy "mongo" shell, not mongosh.
  RESULT=$(oc exec "$ORDERS_DB_POD" -n "$NAMESPACE" -- mongo data --quiet \
    --eval "printjson(db.customerOrder.findOne({_id: ObjectId(\"$ORDER_ID\")}))" 2>&1)
  if echo "$RESULT" | grep -q "$CUSTOMER_ID"; then
    echo "  OK    found order $ORDER_ID for customer $CUSTOMER_ID in orders-db: data.customerOrder"
    BACKEND_PASS=$((BACKEND_PASS + 1))
  else
    echo "  FAIL  order $ORDER_ID not found (or customer mismatch) in orders-db. Raw result:"
    echo "        $RESULT"
    BACKEND_FAIL=$((BACKEND_FAIL + 1))
  fi
else
  echo "  SKIP  no orderId captured from the flow test above (it must have failed earlier)"
  BACKEND_FAIL=$((BACKEND_FAIL + 1))
fi

echo
echo "===================================="
echo "  HTTP flow:      $([ $FLOW_STATUS -eq 0 ] && echo PASSED || echo FAILED)"
echo "  Backend checks: $BACKEND_PASS passed, $BACKEND_FAIL failed"
echo "===================================="

[ $FLOW_STATUS -eq 0 ] && [ $BACKEND_FAIL -eq 0 ]
