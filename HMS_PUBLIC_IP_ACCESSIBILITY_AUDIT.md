# HMS Public IP Accessibility Audit

**Document type:** Read-only network and deployment audit  
**Target deployment:** `/opt/HMS/docker` on Linux production host (example: `SAFI-HOSPITAL-CMS`)  
**Audit date:** 2026-11-05  
**Auditor role:** Senior Linux DevOps / Network Engineering (repository + runbook review)

**Scope:** Determine whether HMS can be reached as `http://<PUBLIC_IP>:8088` (and related API paths) from arbitrary client machines, and recommend a secure production architecture.

**Safety constraints observed for this audit:** No changes to Docker Compose, `.env`, PostgreSQL, firewall, containers, or images. No port openings. No rebuilds.

---

## Executive summary

| Area | Status |
|------|--------|
| Application stack design for browser access via web port | **Favorable** — SPA uses same-origin API via nginx inside `hms-web` |
| Default Compose port publish semantics | **Favorable** — short port syntax publishes on all host interfaces (`0.0.0.0`) unless overridden |
| On-server bind address / listener verification | **Not executed in this audit** — requires commands on the host |
| Host firewall (UFW) | **Operator-reported inactive** — must be re-verified; other filter tables may still apply |
| Public IP / NAT / upstream firewall | **Not verified** — likely gating factor if LAN access works but internet access fails |
| External-network accessibility test | **Not performed** — cannot claim public reachability until tested off-premise |

**Primary hypothesis (assumption, not verified):** If the UI works on `http://127.0.0.1:8088` on the server but not via `<PUBLIC_IP>:8088` from another PC, the cause is usually **(1) missing DNAT/port-forward or cloud security group rules**, **(2) an upstream hospital/campus firewall**, or **(3) publishing bound to loopback only** — not the HMS application code path itself.

---

## 1. Current network architecture

### 1.1 Logical diagram (verified from repository)

```text
                    [ Client browsers ]
                            |
            HTTP :8088 (web)  |  HTTP :8080 (API, optional direct)
                            v
              +-----------------------------+
              |  Linux host (bare metal/VM) |
              |  NIC: private LAN (RFC1918) |
              +-----------------------------+
                    |                |
         publish    |                |  host.docker.internal:5432
         :8088→:80   |                |  (via compose extra_hosts)
                    v                v
         +----------------+   +----------------+
         | docker-hms-web |   | docker-hms-api |
         | nginx :80      |-->| OFBiz/Tomcat |
         | SPA static     |   | JDBC         |
         +----------------+   +--------+-------+
                                       |
                                       v
                         +---------------------------+
                         | PostgreSQL 18 (native)    |
                         | Primary: hms_db :5432     |
                         | Standby/replica (separate)|
                         +---------------------------+
```

**Verified sources:** `docker/docker-compose.yml`, `hms-web/docker/nginx.conf`, `hms-web/docker/40-app-config.sh`, `docker/HMS_LINUX_DEPLOYMENT_AND_DATABASE_GUIDE.md`.

### 1.2 Traffic paths

| Path | Description | Verified? |
|------|-------------|-----------|
| Browser → `host:8088` → nginx → static SPA | Standard UI entry | Yes (compose + nginx) |
| Browser → `host:8088/hms/...` → nginx → `hms-api:80` | Same-origin API proxy | Yes (nginx.conf) |
| Browser → `host:8088/api/auth/...` → nginx → API | Auth proxy | Yes (nginx.conf) |
| Browser → `host:8080/...` | Direct API exposure on host port | Yes (compose maps API container :80 → host :8080) |
| `hms-api` → PostgreSQL | JDBC to host gateway, not replica | Yes (compose env + docs) |
| Internet → PostgreSQL :5432 | Must **not** exist | Policy (audit requirement) |

### 1.3 Docker internal networking

- Services share the default Compose bridge network.
- `hms-web` uses `HMS_WEB_API_UPSTREAM: http://hms-api:80` (container DNS name).
- `hms-api` uses `extra_hosts: host.docker.internal:host-gateway` to reach native PostgreSQL on the host.

---

## 2. Current IP addresses

**Rule:** Do not document live public IPs, passwords, or credentials in operational tickets. Use placeholders below.

| Address role | Value in this audit | Evidence |
|--------------|---------------------|----------|
| Public IPv4 | `<PUBLIC_IP>` — **unknown / not verified here** | Not measured in this audit |
| Private/LAN IPv4 | `<PRIVATE_HOST_IP>` on `/29` segment (example class: `172.30.1.0/29`) | **Operator-reported** in deployment session (host `.4`, gateway `.1`, interface `eno5d1`) |
| Default route | Via LAN gateway `<GW_IP>` | **Operator-reported** |
| Docker bridge | Typical `172.17.0.0/16`, `172.18.0.0/16` | **Operator-reported** (`docker0`, compose bridge) |
| Loopback | `127.0.0.1` | Standard |

**Assumption:** `<PUBLIC_IP>` may be the WAN address of a hospital edge router performing **NAT** to `<PRIVATE_HOST_IP>`, or a cloud provider **elastic IP** bound to the VM. Which applies is **unverified**.

---

## 3. Verified Docker port mappings (from repository)

From `docker/docker-compose.yml`:

| Service | Compose `ports` entry | Container port | Default host port | Bind address in file |
|---------|----------------------|----------------|-------------------|----------------------|
| `hms-api` | `${HMS_API_PORT:-8080}:80` | 80 | **8080** | **Not specified** → Docker default is all interfaces |
| `hms-web` | `${HMS_WEB_PORT:-8088}:80` | 80 | **8088** | **Not specified** → Docker default is all interfaces |

From `docker/.env.example` (defaults only — **production `.env` not read in this audit**):

- `HMS_API_PORT=8080`
- `HMS_WEB_PORT=8088`

**Important:** If production `.env` ever sets `HMS_*_PORT` to a form like `127.0.0.1:8088:80`, the service would be **localhost-only**. That override is **not present in the committed compose/example files** but must be confirmed on the server.

**Docker Compose behavior (industry standard, not re-tested on your host):** The short syntax `"8088:80"` is equivalent to `"0.0.0.0:8088:80"` for IPv4 publish.

---

## 4. Firewall status

| Layer | Finding | Verified? |
|-------|---------|-----------|
| UFW | **Inactive** (`Status: inactive`) | **Operator-reported** during server troubleshooting — **re-verify** |
| nftables/iptables | Not inspected | **Not verified** |
| Docker `DOCKER-USER` chain | Not inspected | **Not verified** |
| SELinux/AppArmor | Not inspected | **Not verified** |
| Campus/hospital edge firewall | Unknown | **Assumption** — often blocks inbound non-standard ports |
| Cloud security group / NSG | Unknown | **Assumption** if VM is in cloud |

**Note:** Even with UFW disabled, **iptables rules installed by Docker** usually allow forwarded/published container ports on the host. Lack of UFW does **not** imply public internet access.

---

## 5. Connectivity test results

### 5.1 Tests performed during this audit

| Test | Result |
|------|--------|
| External client → `<PUBLIC_IP>:8088` | **Not performed** (no access from separate network in this audit) |
| External client → `<PUBLIC_IP>:8080` | **Not performed** |
| On-server `curl` to LAN IP | **Not performed in this audit** |
| On-server `docker compose ps` / `ss -tlnp` | **Not performed in this audit** (per safety: no container restarts; read-only commands were not executed on host from here) |

### 5.2 Operator-reported historical results (prior sessions, not re-run here)

| Test | Reported outcome |
|------|------------------|
| `docker compose build` / `up -d hms-web` | Successful at least once |
| `git pull` to Azure DevOps | Intermittent failures due to **IPv6 unreachable**; workaround `/etc/hosts` for `dev.azure.com` |
| Default route | Private LAN only (`172.30.1.0/29` style) |
| UFW | Inactive |

Treat prior session data as **context**, not as a substitute for a fresh on-server checklist (Section 9).

### 5.3 Recommended read-only verification commands (run on server)

Run these **without** changing configuration:

```bash
# Identity and routing
hostname -I
ip -4 addr show
ip route show default

# Published ports and bind addresses (critical)
cd /opt/HMS/docker
docker compose ps
docker port docker-hms-web-1 80 2>/dev/null || docker compose port hms-web 80
docker port docker-hms-api-1 80 2>/dev/null || docker compose port hms-api 80
ss -tlnp | grep -E ':8080|:8088'

# Local vs LAN vs public (replace <PRIVATE_HOST_IP>)
curl -s -o /dev/null -w "loopback web %{http_code}\n" http://127.0.0.1:8088/
curl -s -o /dev/null -w "LAN web %{http_code}\n"     http://<PRIVATE_HOST_IP>:8088/
curl -s -o /dev/null -w "loopback api %{http_code}\n" http://127.0.0.1:8080/
curl -s -o /dev/null -w "LAN api %{http_code}\n"     http://<PRIVATE_HOST_IP>:8080/

# Host firewall
sudo ufw status verbose 2>/dev/null || true
sudo nft list ruleset 2>/dev/null | head -n 80
sudo iptables -S DOCKER-USER 2>/dev/null || true

# Confirm PostgreSQL is NOT listening on public interfaces (audit policy)
ss -tlnp | grep 5432 || true
```

From **another machine on the same LAN**:

```bash
curl -sI "http://<PRIVATE_HOST_IP>:8088/" | head
```

From **outside the hospital network** (home/mobile, not VPN):

```bash
curl -sI --connect-timeout 5 "http://<PUBLIC_IP>:8088/" | head
```

Only after a successful **external** test may you claim public accessibility.

---

## 6. Identified issues and risk factors

### 6.1 Verified / documented (no host test required)

| ID | Issue | Severity | Notes |
|----|-------|----------|-------|
| V1 | HTTP only on default deployment | High for production | No TLS in Compose; credentials traverse network in cleartext if not fronted by HTTPS |
| V2 | API port 8080 may be exposed alongside 8088 | Medium | Increases attack surface; UI can work through 8088 alone |
| V3 | PostgreSQL must stay off public internet | Critical | Compose does not publish 5432 — maintain that |
| V4 | Replica/standby not used by app | Info | Correct; app must remain on primary only |

### 6.2 Operator-reported / environmental

| ID | Issue | Severity | Notes |
|----|-------|----------|-------|
| E1 | IPv6 broken on host (no route) | Medium | Affects outbound pulls/git, not necessarily inbound HMS HTTP if clients use IPv4 |
| E2 | DNS/timeouts to systemd-resolved (`127.0.0.53`) | Low–Medium | Can cause flaky outbound; use read-only diagnostics |
| E3 | UFW inactive | Info | Host may still be protected by **external** firewall only |

### 6.3 Unverified (must confirm on site)

| ID | Issue | Why it matters |
|----|-------|----------------|
| U1 | Upstream firewall blocks inbound 8088/8080 | Most common reason public IP fails while localhost works |
| U2 | No NAT/port-forward from `<PUBLIC_IP>` → `<PRIVATE_HOST_IP>` | Server on private LAN needs DNAT |
| U3 | Compose bind override to `127.0.0.1` in effective config | Would block LAN/public while loopback works |
| U4 | Another process or security appliance intercepts ports | Rare but possible |
| U5 | Split-horizon / hairpin NAT | Internal users using public IP may fail even when external users succeed |

---

## 7. Why localhost works but public IP may fail

| Scenario | Symptom | Typical cause |
|----------|---------|---------------|
| A | Works on server `127.0.0.1:8088`, fails on `<PUBLIC_IP>:8088` from outside | No port-forward / security group / ACL |
| B | Works on server loopback, fails on `<PRIVATE_HOST_IP>:8088` from LAN | Bind to `127.0.0.1` only, or host iptables |
| C | Works on LAN IP, fails on public IP | NAT or edge firewall |
| D | UI loads but login/API fails | Usually **not** separate public API URL in Docker deploy (`app-config.js` uses same-origin `apiUrl: ""`) — look for mixed content, wrong tenant, or API down |
| E | Works without VPN, fails with VPN | Split tunnel / corporate firewall |

**Verified for Docker web image:** `40-app-config.sh` sets `window.__HMSERP_CONFIG__ = { apiUrl: "" }`, so the browser should call the **same host and port** as the UI (nginx proxies `/hms/` and `/api/auth/`). Users should **not** need to open `:8080` in the browser for normal operation.

---

## 8. Required changes (recommendations only — not applied)

Changes are grouped by goal. Implement only after change control.

### 8.1 Minimum for `http://<PUBLIC_IP>:8088` (not recommended as final production state)

1. Confirm Docker publishes `0.0.0.0:8088` (Section 5.3).
2. Allow inbound **TCP 8088** on **edge** firewall / router DNAT to `<PRIVATE_HOST_IP>:8088`.
3. Optionally **do not** expose 8080 publicly; rely on nginx on 8088.
4. Test from an **external** network.

### 8.2 Recommended production architecture

```text
 [ Internet clients ]
         |
         |  HTTPS :443 (only)
         v
 +------------------+
 | Reverse proxy    |  nginx or HAProxy on host OR dedicated VM
 | (TLS termination)|
 +------------------+
         | HTTP to localhost or docker bridge
         v
   :8088 hms-web (or remap to :80 internally)
         |
         +--> hms-api via internal docker network (not public)

 PostgreSQL :5432  bound to 127.0.0.1 or private DB VLAN only
 Replica       :5433 (or separate host) — replication + admin only
```

| Topic | Recommendation |
|-------|----------------|
| **Direct public IP on 8088** | Acceptable only as temporary; prefer **443 + domain** |
| **Nginx reverse proxy** | **Recommended** — TLS, rate limits, security headers, single entry |
| **Domain** | `hms.<hospital-domain>` A/AAAA record to public IP or load balancer |
| **HTTPS** | Let’s Encrypt (if public DNS) or hospital internal CA |
| **Secure API** | Do not expose `:8080` publicly; keep API behind nginx; add WAF if required |
| **PostgreSQL** | `listen_addresses` limited; `pg_hba` only Docker bridge + localhost; **never** 0.0.0.0:5432 to internet |
| **Primary vs replica** | HMS API → **primary only**; replica for DR/reporting via private paths; replication user **SCRAM**, **127.0.0.1** or private link only |

### 8.3 Hardening after exposure

- Enable host firewall: allow **22/SSH** (or jump host only), **443**, deny everything else inbound by default.
- Fail2ban or equivalent on proxy logs.
- Central logging and backup verification (already in deployment guide).

---

## 9. Step-by-step implementation procedure (future change window)

**Phase 0 — Read-only audit (this document)**  
Complete Section 5.3 on the server and external client tests. Record results in your change ticket.

**Phase 1 — Prove LAN access**

1. From a PC on the hospital LAN, open `http://<PRIVATE_HOST_IP>:8088`.
2. If fail: fix bind address / local firewall before touching public NAT.

**Phase 2 — Edge/network**

1. Identify who owns **public IP** and **edge firewall** (IT/network team).
2. Request **inbound TCP 8088** (temporary) or **443** (preferred) DNAT to `<PRIVATE_HOST_IP>`.
3. Document source IP restrictions if policy requires (e.g. VPN-only).

**Phase 3 — Reverse proxy + TLS (recommended)**

1. Install nginx on host or separate tier.
2. Obtain certificate for FQDN.
3. Proxy `https://hms.example.org/` → `http://127.0.0.1:8088`.
4. Add HSTS, modern TLS ciphers, `X-Forwarded-*` headers (nginx in container already honors some).

**Phase 4 — Reduce exposure**

1. Remove public 8080 if it was opened.
2. Restrict Docker publish to `127.0.0.1:8088` **only when** fronted by local nginx on 443.
3. Re-enable UFW with explicit rules.

**Phase 5 — Validation**

1. External `curl -sI https://hms.example.org/`.
2. Full login and critical workflows (OPD, billing) from external client.
3. Confirm `ss -tlnp | grep 5432` shows no public bind.

---

## 10. Rollback procedure

If a change window causes outage or unacceptable risk:

| Change made | Rollback |
|-------------|----------|
| Edge port-forward / ACL for 8088 or 443 | Remove DNAT/ACL rule at router/firewall |
| UFW rules added | `sudo ufw delete <rule>` or `sudo ufw disable` (only if that was prior state) |
| Host nginx reverse proxy | Stop/disable nginx site; clients use previous URL or internal-only access |
| TLS certificate experiment | Revert nginx `server` block to previous config; reload nginx |
| Docker publish changed to 127.0.0.1 | Restore previous `ports` mapping in Compose **via change control** (out of scope for this audit file edit) |
| Accidental public 5432 | Close firewall; fix `postgresql.conf` / `pg_hba.conf` under DBA procedure |

**Safe baseline:** HMS reachable only on hospital LAN or via approved VPN — no inbound internet ports.

---

## 11. Evaluation matrix: access patterns

| Pattern | Pros | Cons | Verdict |
|---------|------|------|---------|
| **Direct `http://PUBLIC_IP:8088`** | Fastest to test | No encryption; non-standard port; hard to remember; broad exposure | Temporary / lab only |
| **Direct `http://PUBLIC_IP:8080` API** | Debugging | Unnecessary for SPA; high risk | **Do not** expose publicly |
| **Nginx + domain + HTTPS** | Standard, secure, auditable | Requires cert and DNS | **Production best practice** |
| **VPN-only access** | Strong access control | Users need VPN client | **Common in hospitals** — often better than raw public IP |
| **Split: public read-only vs VPN write** | Policy fit | Complex | Only if product/security requires |

---

## 12. PostgreSQL and replication isolation (audit view)

| Component | Expected binding | Public exposure |
|-----------|------------------|-----------------|
| Primary `hms_db` :5432 | localhost + Docker bridge (via `pg_hba`) | **Must be NO** |
| Standby/replica (e.g. :5433) | localhost or private replication network | **Must be NO** |
| `replicator` role | Replication protocol only; SCRAM | Never on 0.0.0.0/0 |
| HMS API JDBC | `host.docker.internal:5432` → primary | Internal only |

**Verified from documentation:** HMS API does not connect to replica; replication is asynchronous physical standby.

---

## 13. Summary checklist for network team

- [ ] Confirm `<PUBLIC_IP>` ownership and NAT to `<PRIVATE_HOST_IP>`
- [ ] Confirm inbound allow list (8088 temporary or 443 final)
- [ ] Confirm PostgreSQL **not** reachable from internet
- [ ] On-server: `ss -tlnp` shows `0.0.0.0:8088` or intentional `127.0.0.1` + reverse proxy
- [ ] LAN browser test → external browser test (no VPN)
- [ ] Plan HTTPS and disable cleartext public access
- [ ] Document rollback and monitoring

---

## Document control

| Field | Value |
|-------|-------|
| Version | 1.0 |
| Verified from repo | `docker-compose.yml`, `.env.example`, `hms-web/docker/nginx.conf`, `40-app-config.sh`, deployment guides |
| Live host state | **Partially** inferred from operator sessions — must complete Section 5.3 |
| External accessibility | **Not claimed** in this audit |

*End of audit report.*
