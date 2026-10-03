#!/usr/bin/env bash
# 敏感短语清单端到端示例：
#   查询初始清单（空清单 = 停用核验）-> 鉴权 401、空短语/重复 422 ->
#   原子替换并查询（版本递增）->
#   直接发布核验：未覆盖命中 422 只回命中位置、不产生快照；补齐区间后 201 ->
#   受控申请提交核验 -> 批准时用当时启用清单重新核验冻结原文
#   （不合格 422，申请保持待审且仍可驳回；清单停用后可批准）->
#   空清单停用核验 -> 清单变更不影响已发布快照与既有凭证
# 依赖：curl、jq
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
SERVICE_KEY="${SERVICE_KEY:-dev-service-key-change-me}"
ALICE_PW="${ALICE_PW:-alice-pw}"   # operator
BOB_PW="${BOB_PW:-bob-pw}"         # reviewer
AUTH=(-H "X-Service-Key: ${SERVICE_KEY}" -H "Content-Type: application/json")

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
code() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }

step "1. 查询初始清单：空清单表示停用核验（从未替换过时 version 为 0）"
curl -sS "${BASE_URL}/sensitive-phrases" -H "X-Service-Key: ${SERVICE_KEY}" | jq .

step "2. 明确拒绝：缺/错服务密钥 401；空短语、清单内重复 422"
printf '缺密钥 GET:  HTTP %s\n' "$(code "${BASE_URL}/sensitive-phrases")"
printf '错密钥 PUT:  HTTP %s\n' "$(code -X PUT "${BASE_URL}/sensitive-phrases" \
  -H "X-Service-Key: wrong" -H 'Content-Type: application/json' -d '{"phrases":["张三"]}')"
printf '空短语:      HTTP %s\n' "$(code -X PUT "${BASE_URL}/sensitive-phrases" "${AUTH[@]}" \
  -d '{"phrases":[""]}')"
printf '清单内重复:  HTTP %s\n' "$(code -X PUT "${BASE_URL}/sensitive-phrases" "${AUTH[@]}" \
  -d '{"phrases":["张三","张三"]}')"

step "3. 原子替换为启用清单并查询（每次成功替换 version +1）"
curl -sS -X PUT "${BASE_URL}/sensitive-phrases" "${AUTH[@]}" \
  -d '{"phrases":["张三","110101199003077777"]}' | jq .
curl -sS "${BASE_URL}/sensitive-phrases" -H "X-Service-Key: ${SERVICE_KEY}" | jq .

step "4. 直接发布核验：电话 13800001111 命中但未遮蔽 -> 422 只回命中位置，不产生快照"
CREATE=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "患者张三，身份证号 110101199003077777，联系电话 13800001111。",
  "intervals": [{"start": 2, "end": 4}, {"start": 10, "end": 28}]
}')
RID=$(echo "${CREATE}" | jq -r .record_id)
curl -sS -X PUT "${BASE_URL}/sensitive-phrases" "${AUTH[@]}" \
  -d '{"phrases":["张三","13800001111"]}' >/dev/null
curl -sS -X POST "${BASE_URL}/records/${RID}/publish" "${AUTH[@]}" -d '{"version": 1}' | jq .
echo "记录快照列表（应为空，未产生快照或令牌）:"
curl -sS "${BASE_URL}/records/${RID}" -H "X-Service-Key: ${SERVICE_KEY}" | jq .snapshots

step "5. 修订补齐遮蔽区间（覆盖电话 [34,45)）后发布成功"
curl -sS -X PUT "${BASE_URL}/records/${RID}" "${AUTH[@]}" -d '{
  "base_version": 1,
  "text": "患者张三，身份证号 110101199003077777，联系电话 13800001111。",
  "intervals": [{"start": 2, "end": 4}, {"start": 10, "end": 28}, {"start": 34, "end": 45}]
}' >/dev/null
PUB=$(curl -sS -X POST "${BASE_URL}/records/${RID}/publish" "${AUTH[@]}" -d '{"version": 2}')
SID=$(echo "${PUB}" | jq -r .snapshot_id)
TOK=$(echo "${PUB}" | jq -r .token)
echo "${PUB}" | jq '{snapshot_id, version, status, token}'

step "6. 受控申请提交同样核验：未覆盖命中 422 且不生成申请"
curl -sS -X PUT "${BASE_URL}/records/${RID}/controlled" -H "X-Service-Key: ${SERVICE_KEY}" | jq .
curl -sS -X PUT "${BASE_URL}/records/${RID}" "${AUTH[@]}" -d '{
  "base_version": 2,
  "text": "患者李四，联系电话 13800001111。",
  "intervals": [{"start": 2, "end": 4}]
}' >/dev/null
curl -sS -X POST "${BASE_URL}/records/${RID}/publish-requests" -u "alice:${ALICE_PW}" \
  -H 'Content-Type: application/json' -d '{"version": 3}' | jq .
echo "申请列表（应为空）:"
curl -sS "${BASE_URL}/records/${RID}/publish-requests" -u "alice:${ALICE_PW}" | jq .requests

step "7. 批准时用当时启用的清单重新核验冻结的原文与区间"
# 提交时清单只含已覆盖短语 -> 申请创建成功并冻结版本 3 内容
curl -sS -X PUT "${BASE_URL}/sensitive-phrases" "${AUTH[@]}" -d '{"phrases":["李四"]}' >/dev/null
SUBMIT=$(curl -sS -X POST "${BASE_URL}/records/${RID}/publish-requests" -u "alice:${ALICE_PW}" \
  -H 'Content-Type: application/json' -d '{"version": 3}')
PRID=$(echo "${SUBMIT}" | jq -r .request_id)
echo "${SUBMIT}" | jq '{request_id, version, status}'
# 批准前把清单换成含未覆盖短语 -> 批准 422，申请保持待审
curl -sS -X PUT "${BASE_URL}/sensitive-phrases" "${AUTH[@]}" \
  -d '{"phrases":["13800001111"]}' >/dev/null
curl -sS -X POST "${BASE_URL}/publish-requests/${PRID}/approve" -u "bob:${BOB_PW}" | jq .
curl -sS "${BASE_URL}/publish-requests/${PRID}" -u "alice:${ALICE_PW}" | jq '{status, snapshot_id}'
# 待审申请仍可驳回
curl -sS -X POST "${BASE_URL}/publish-requests/${PRID}/reject" -u "bob:${BOB_PW}" \
  -H 'Content-Type: application/json' -d '{"reason":"待清单调整后再议"}' | jq '{status, reason}'

step "8. 清单停用（空清单）后，相同原文可提交申请并批准签发"
curl -sS -X PUT "${BASE_URL}/sensitive-phrases" "${AUTH[@]}" -d '{"phrases":[]}' | jq .
SUBMIT2=$(curl -sS -X POST "${BASE_URL}/records/${RID}/publish-requests" -u "alice:${ALICE_PW}" \
  -H 'Content-Type: application/json' -d '{"version": 3}')
PRID2=$(echo "${SUBMIT2}" | jq -r .request_id)
APPROVE=$(curl -sS -X POST "${BASE_URL}/publish-requests/${PRID2}/approve" -u "bob:${BOB_PW}")
echo "${APPROVE}" | jq '{status, snapshot_id, token}'

step "9. 清单变更不改变已发布快照与既有凭证：步骤 5 的令牌继续可读"
curl -sS -X PUT "${BASE_URL}/sensitive-phrases" "${AUTH[@]}" \
  -d '{"phrases":["13800001111","患者"]}' >/dev/null
curl -sS "${BASE_URL}/public/snapshots/${SID}?token=${TOK}" | jq .

step "10. 收尾：还原为空清单（停用核验）"
curl -sS -X PUT "${BASE_URL}/sensitive-phrases" "${AUTH[@]}" -d '{"phrases":[]}' | jq .

printf '\n\033[1m敏感短语清单演示完成。\033[0m\n'
