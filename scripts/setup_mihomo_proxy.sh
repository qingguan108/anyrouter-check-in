#!/usr/bin/env bash
# 通过 mihomo 拉取订阅、启动本地代理并探测可用节点。
# 环境变量:
#   PROXY_SUBSCRIPTION_URL  订阅链接（必填才启用）
#   PROXY_TEST_URL          探测目标，默认 https://www.google.com/generate_204
#   PROXY_VALIDATION_URL    节点必须返回 JSON 的业务接口（可选）
#   PROXY_REQUIRED          true 时探测失败则退出 1
#   PROXY_PORT              本地 mixed-port，默认 7890

set -euo pipefail

if [[ -z "${PROXY_SUBSCRIPTION_URL:-}" ]]; then
	echo "[INFO] PROXY_SUBSCRIPTION_URL not set, skip proxy setup"
	exit 0
fi

PROXY_DIR="${RUNNER_TEMP:-/tmp}/checkin-proxy"
PROXY_PORT="${PROXY_PORT:-7890}"
PROXY_TEST_URL="${PROXY_TEST_URL:-https://www.google.com/generate_204}"
PROXY_VALIDATION_URL="${PROXY_VALIDATION_URL:-}"
PROXY_MAX_VALIDATION_NODES="${PROXY_MAX_VALIDATION_NODES:-20}"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.0}"
PROXY_REQUIRED="${PROXY_REQUIRED:-false}"

mkdir -p "${PROXY_DIR}"
cd "${PROXY_DIR}"

echo "[INFO] Downloading mihomo ${MIHOMO_VERSION}..."
ARCHIVE="mihomo-linux-amd64-${MIHOMO_VERSION}.gz"
if ! curl --retry 3 --retry-delay 5 --retry-all-errors -fsSL -o "${ARCHIVE}" \
	"https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${ARCHIVE}"; then
	echo "[WARN] Failed to download mihomo ${MIHOMO_VERSION}, skip proxy setup"
	if [[ "${PROXY_REQUIRED}" == "true" ]]; then
		exit 1
	fi
	exit 0
fi
gunzip -f "${ARCHIVE}"
chmod +x "mihomo-linux-amd64-${MIHOMO_VERSION}"
MIHOMO_BIN="${PROXY_DIR}/mihomo-linux-amd64-${MIHOMO_VERSION}"

cat > config.yaml <<EOF
mixed-port: ${PROXY_PORT}
external-controller: 127.0.0.1:9090
allow-lan: false
ipv6: false
mode: rule
log-level: warning
unified-delay: true

proxy-providers:
  subscription:
    type: http
    url: "${PROXY_SUBSCRIPTION_URL}"
    interval: 3600
    path: ./subscription.yaml
    health-check:
      enable: true
      interval: 300
      url: https://www.gstatic.com/generate_204

proxy-groups:
  - name: CHECKIN
    type: select
    use:
      - subscription

rules:
  - MATCH,CHECKIN
EOF

echo "[INFO] Starting mihomo on 127.0.0.1:${PROXY_PORT}..."
nohup "${MIHOMO_BIN}" -d "${PROXY_DIR}" -f config.yaml > mihomo.log 2>&1 &
echo $! > mihomo.pid

PROXY_URL="http://127.0.0.1:${PROXY_PORT}"

if [[ -n "${PROXY_VALIDATION_URL}" ]]; then
	CONTROLLER_URL="http://127.0.0.1:9090"
	NODES=()
	for attempt in $(seq 1 30); do
		if GROUP_JSON=$(curl -fsS --max-time 5 "${CONTROLLER_URL}/proxies/CHECKIN" 2>/dev/null); then
			mapfile -t NODES < <(printf '%s' "${GROUP_JSON}" | jq -r '.all[]?')
			if [[ "${#NODES[@]}" -gt 0 ]]; then
				break
			fi
		fi
		sleep 1
	done

	echo "[INFO] Found ${#NODES[@]} proxy node(s); validating up to ${PROXY_MAX_VALIDATION_NODES} against target"
	VALID_NODE=false
	NODE_INDEX=0
	for NODE in "${NODES[@]}"; do
		NODE_INDEX=$((NODE_INDEX + 1))
		if [[ "${NODE_INDEX}" -gt "${PROXY_MAX_VALIDATION_NODES}" ]]; then
			break
		fi

		SELECT_PAYLOAD=$(jq -nc --arg name "${NODE}" '{name: $name}')
		if ! curl -fsS --max-time 5 -X PUT -H 'Content-Type: application/json' \
			-d "${SELECT_PAYLOAD}" "${CONTROLLER_URL}/proxies/CHECKIN" -o /dev/null; then
			continue
		fi

		RESPONSE_BODY="${PROXY_DIR}/validation-response-${NODE_INDEX}.txt"
		if RESPONSE_META=$(curl -sS -x "${PROXY_URL}" --max-time 20 \
			-o "${RESPONSE_BODY}" -w '%{http_code}|%{content_type}' "${PROXY_VALIDATION_URL}"); then
			CONTENT_TYPE="${RESPONSE_META#*|}"
			if [[ "${CONTENT_TYPE}" == application/json* ]] && jq -e . "${RESPONSE_BODY}" >/dev/null 2>&1; then
				echo "[SUCCESS] Proxy node ${NODE_INDEX}/${#NODES[@]} passed target JSON validation"
				VALID_NODE=true
				break
			fi
		fi
		echo "[INFO] Proxy node ${NODE_INDEX}/${#NODES[@]} did not pass target validation"
	done

	if [[ "${VALID_NODE}" != "true" ]]; then
		echo "[FAILED] No tested proxy node can reach the target without a WAF page"
		if [[ "${PROXY_REQUIRED}" == "true" ]]; then
			exit 1
		fi
	fi
fi

READY=false
for attempt in $(seq 1 45); do
	if curl -fsS -x "${PROXY_URL}" --max-time 20 "${PROXY_TEST_URL}" -o /dev/null 2>/dev/null; then
		READY=true
		break
	fi
	echo "[INFO] Waiting for proxy health check (${attempt}/45)..."
	sleep 2
done

if [[ "${READY}" != "true" ]]; then
	echo "[FAILED] Proxy health check failed for ${PROXY_TEST_URL}"
	tail -n 30 mihomo.log || true
	if [[ -f mihomo.pid ]]; then
		kill "$(cat mihomo.pid)" 2>/dev/null || true
	fi
	if [[ "${PROXY_REQUIRED}" == "true" ]]; then
		exit 1
	fi
	exit 0
fi

echo "[SUCCESS] Proxy is ready: ${PROXY_URL}"
echo "[INFO] Proxy is scoped to CHECKIN_PROXY_URL (browser/python only, not global HTTP_PROXY)"
if [[ -n "${GITHUB_ENV:-}" ]]; then
	echo "CHECKIN_PROXY_URL=${PROXY_URL}" >> "${GITHUB_ENV}"
fi
