# WebSocket Connections Dropping at Exactly 30 Seconds in Production

Alex, the 30-second timeout is a dead giveaway. This is almost certainly **not** nginx itself -- it's a **load balancer or reverse proxy sitting in front of nginx** that you haven't configured for WebSocket upgrades.

## The Root Cause

The exact 30-second cutoff tells us this is an **idle connection timeout at an infrastructure layer**, not an application-level issue. Here's the diagnostic reasoning:

1. **"Upstream timed out"** means nginx thinks the backend is unresponsive -- but the backend is fine (works locally).
2. **keep-alive at 300s doesn't help** because keep-alive governs HTTP persistent connections, not WebSocket frame-level activity.
3. **ping/pong didn't help** -- this suggests the ping/pong frames aren't reaching the upstream because the connection is being killed *before* nginx even considers its own timeout settings.
4. **Exactly 30 seconds** is the default idle timeout for AWS ALB, GCP Load Balancer, Cloudflare, and many cloud reverse proxies.

The most likely scenario: there's a layer between the client and nginx (cloud load balancer, CDN, or another reverse proxy) that is either:
- **Not upgraded to WebSocket** and treating the connection as a stalled HTTP request
- **Applying its own idle timeout** of 30 seconds to what it sees as an inactive connection

## Immediate Diagnostic Steps

### 1. Identify all layers in the request path

```bash
# Trace the full path from client to your app
# Client -> [CDN?] -> [Cloud LB?] -> nginx -> app

# Check if there's a load balancer in front of nginx
curl -v -I https://your-domain.com 2>&1 | grep -i 'server\|via\|x-served-by\|x-cache'
```

If you see headers like `server: cloudflare`, `via: 1.1 google`, `server: awselb/2.0`, etc., that's your culprit.

### 2. Check nginx is actually receiving the WebSocket upgrade

Add this to your nginx access log format temporarily:

```nginx
log_format ws_debug '$remote_addr - $request - $status - '
                    '$upstream_status - $http_upgrade - $http_connection - '
                    '$upstream_response_time';
```

Then check: is `$http_upgrade` showing "websocket"? If it's empty, the upgrade header is being stripped by an upstream layer.

### 3. Verify your nginx WebSocket config is actually being hit

The config you need (which you likely already have, but confirm it's on the right `location` block):

```nginx
location /ws {
    proxy_pass http://your_backend;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
}
```

**Critical check**: is the WebSocket path actually matching this location block? Add `return 200 "hit";` temporarily to confirm.

## Fixes Based on Infrastructure

### If AWS ALB / ELB

- Classic ELB: **Does not support WebSocket at all on HTTP listener.** You must use a TCP listener or switch to ALB.
- ALB: Supports WebSocket, but the **idle timeout defaults to 60s** (not 30s -- so if you're seeing 30s, check if someone changed it). Go to EC2 -> Load Balancers -> Attributes -> Idle timeout.

```bash
# Check ALB idle timeout
aws elbv2 describe-load-balancer-attributes \
  --load-balancer-arn YOUR_ARN \
  --query "Attributes[?Key=='idle_timeout.timeout_seconds']"
```

### If Cloudflare

Cloudflare's free/pro plan has a **100-second WebSocket idle timeout**, but if you're on a plan that doesn't support WebSocket or have it misconfigured, connections die fast. Check:
- WebSocket is enabled in the dashboard (Network tab)
- If using Cloudflare Tunnel, the tunnel itself may have a different timeout

### If GCP Load Balancer

```bash
# GCP default backend service timeout is 30 seconds -- this is very likely your problem
gcloud compute backend-services describe YOUR_BACKEND_SERVICE \
  --global --format="get(timeoutSec)"

# Fix it:
gcloud compute backend-services update YOUR_BACKEND_SERVICE \
  --global --timeout=86400
```

### If there's another nginx/HAProxy in front

Check for a second reverse proxy you might have forgotten about (common in Docker/Kubernetes setups):

```bash
# Check if there's another process listening on 80/443
ss -tlnp | grep -E ':80|:443'

# In Kubernetes, check ingress controller config
kubectl get ingress -A -o yaml | grep -A5 timeout
```

## Why Your Previous Attempts Failed

| What you tried | Why it didn't work |
|---|---|
| Increasing nginx timeout | The timeout isn't at nginx -- it's upstream of nginx |
| Adding ping/pong | Ping/pong keeps the *WebSocket* alive, but the layer killing you doesn't understand WebSocket frames -- it sees an idle TCP/HTTP connection |
| Switching to socket.io | socket.io adds transport fallback but the underlying WebSocket transport hits the same infrastructure timeout; if it fell back to long-polling it might work, but that's a band-aid |

## Quick Validation Test

To confirm the problem is an infrastructure layer and not nginx:

```bash
# Connect directly to nginx, bypassing any load balancer
# (SSH into the nginx server or use its internal IP)
wscat -c ws://NGINX_INTERNAL_IP:PORT/ws

# If this stays connected past 30 seconds, the problem is
# confirmed to be in front of nginx.
```

## Summary

Stop debugging nginx and your application code. The 30-second exact timeout, combined with "upstream timed out" in nginx logs while keep-alive is set to 300s, points conclusively to an infrastructure layer in front of nginx that either doesn't support WebSocket upgrades or has a short idle connection timeout. Identify what sits between your clients and nginx, and configure that layer for WebSocket support with an appropriate timeout.
