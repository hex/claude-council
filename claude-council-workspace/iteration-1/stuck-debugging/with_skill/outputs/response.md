# WebSocket Drops After 30 Seconds in Production

Alex, you've been fighting this for 2 hours and tried three different approaches. Before I give you my technical analysis, I want to flag something: **this is exactly the kind of debugging dead-end where consulting the council of AI agents could help.** You've been stuck long enough that a fresh set of perspectives might spot something we're both missing. Consider running:

```
/claude-council:ask "WebSocket connections drop after exactly 30 seconds in production behind nginx. Nginx logs show 'upstream timed out' but keep-alive is 300s. Tried: increasing nginx timeout, ping/pong frames, switching to socket.io. What layer is actually killing the connection?"
```

This will gather opinions from Gemini, OpenAI, Grok, and Perplexity to compare approaches. That said, here's what I think is happening based on the symptoms you've described.

---

## The Key Clue: Exactly 30 Seconds

The fact that connections drop at **exactly** 30 seconds -- not 60 (nginx's default `proxy_read_timeout`) and not 300 (your configured keep-alive) -- strongly suggests **the timeout is not coming from nginx at all**. Something upstream of nginx is killing the connection, and nginx is just reporting the symptom.

## Most Likely Root Cause: An Intermediate Layer You Haven't Checked

There are three prime suspects, in order of likelihood:

### 1. A Load Balancer or Cloud Proxy With a 30-Second Idle Timeout

If you're running behind AWS ALB/ELB, DigitalOcean LB, GCP Load Balancer, Cloudflare, or any similar service, **that layer has its own idle timeout that acts independently of nginx**. The default for AWS ALB is 60 seconds, but it can be (and often is) configured lower. If someone set it to 30 seconds, that's your culprit.

**How to check:**
- AWS ALB: `aws elbv2 describe-load-balancer-attributes --load-balancer-arn <arn> | jq '.Attributes[] | select(.Key=="idle_timeout.timeout_seconds")'`
- AWS Classic ELB: `aws elb describe-load-balancer-attributes --load-balancer-name <name>`
- Cloudflare: Check the WebSocket timeout on your plan (100 seconds on free, but proxied connections may behave differently)
- Any CDN or DDoS protection layer in front of nginx

**How to fix (AWS ALB example):**
```bash
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn <arn> \
  --attributes "Key=idle_timeout.timeout_seconds,Value=3600"
```

### 2. The nginx Config Is Not Being Applied to the Right Location Block

A very common mistake: you changed `proxy_read_timeout` in one `location` block or at the `http` level, but the actual WebSocket traffic is hitting a **different** `location` block that still has the default (or an explicit 30s). Nginx picks the most specific matching location.

**How to verify:**
```bash
# Check which location block is actually handling your WebSocket path
nginx -T 2>/dev/null | grep -A 20 "location.*ws\|location.*socket\|proxy_read_timeout\|upstream"
```

Also confirm that your full WebSocket location block includes ALL of these directives:
```nginx
location /your-ws-path {
    proxy_pass http://backend;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;
}
```

### 3. WebSocket Ping/Pong Frames Are NOT Resetting proxy_read_timeout

This is a critical and widely misunderstood point: **nginx's `proxy_read_timeout` is only reset by actual data frames, NOT by WebSocket ping/pong control frames and NOT by TCP keep-alive packets**. So even if your ping/pong mechanism is working perfectly (and you can verify this in server logs), nginx does not consider those as "reads" and the timeout still fires.

This means your fix #2 (adding ping/pong frames) was addressing the wrong layer. Ping/pong keeps the *WebSocket protocol* alive, but doesn't satisfy nginx's `proxy_read_timeout`.

**The fix:** Send actual application-level data messages (even a small JSON heartbeat like `{"type":"heartbeat"}`) instead of or in addition to WebSocket ping frames. These *will* reset the `proxy_read_timeout` counter.

## Debugging Sequence

If I were you, I'd investigate in this order:

1. **Map your full network path.** List every layer between client and your app server: CDN? WAF? Load balancer? Reverse proxy? Identify anything that could impose its own timeout.

2. **Test each layer in isolation.** Connect directly to nginx (bypassing any LB), then connect directly to your app server (bypassing nginx). Find which layer introduces the 30-second cutoff.

3. **Verify the nginx config is actually loaded.** Run `nginx -T` and search for the location block handling your WebSocket path. Confirm `proxy_read_timeout` is set there.

4. **Check if it's idle-only.** If connections that actively send data frames every 20 seconds still drop at 30s, the timeout is likely connection-level (LB), not idle-level (nginx read timeout).

## Why It Works Locally

Locally, you're connecting directly to your app server with no intermediate proxy or load balancer layers. There's no nginx, no ALB, no CDN -- so none of those idle timeouts apply. This is the strongest evidence that the problem is in infrastructure, not in your application code.

## Quick Summary

| What you tried | Why it didn't work |
|---|---|
| Increasing nginx timeout | The 30s timeout likely isn't coming from nginx (default is 60s). Or the config isn't applied to the right location block. |
| Adding ping/pong frames | Nginx doesn't count ping/pong as data reads -- `proxy_read_timeout` is not reset by them. |
| Switching to socket.io | Socket.io still uses WebSocket under the hood in production. The transport layer isn't the problem; the proxy timeout is. |

---

## Sources

- [WebSocket proxying - nginx.org](https://nginx.org/en/docs/http/websocket.html)
- [How to Fix 'upstream timed out' Errors in Nginx](https://oneuptime.com/blog/post/2025-12-16-nginx-upstream-timed-out/view)
- [Nginx for Developers: WebSocket Timeout, HTTPS, and Upload Size Issues](https://blog.devops.dev/nginx-for-developers-practical-guide-to-websocket-timeout-https-wss-and-upload-size-issues-in-24f286132ab9)
- [AWS: Configure idle connection timeout for Classic Load Balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/classic/config-idle-timeout.html)
- [AWS: Edit attributes for Application Load Balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/edit-load-balancer-attributes.html)
- [Elastic Load Balancing Connection Timeout Management - AWS Blog](https://aws.amazon.com/blogs/aws/elb-idle-timeout-control/)
- [Websockets closing after 60s despite proxy-read-timeout set to 3600s - kubernetes/ingress-nginx #5167](https://github.com/kubernetes/ingress-nginx/issues/5167)
- [Tuning Nginx Timeouts to Eliminate Upstream Timeouts - Netdata](https://www.netdata.cloud/academy/nginx-eliminate-upstream-timeout/)
- [Nginx Upstream Timed Out - Better Stack Community](https://betterstack.com/community/questions/nginx-upstream-timed-out/)
- [NGINX Timeout Directives: Complete Configuration Guide](https://www.getpagespeed.com/server-setup/nginx/nginx-timeout)
- [WebSocket Nginx Reverse Proxy Configuration](https://oneuptime.com/blog/post/2026-01-24-websocket-nginx-reverse-proxy/view)
- [AWS Application Load Balancer WebSocket Configuration - WebSocket.org](https://websocket.org/guides/infrastructure/aws/alb/)
