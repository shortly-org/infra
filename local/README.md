# Shortly on one laptop

Needs Docker (Compose v2), `curl` and `jq`. Everything else is in containers. The compose file
builds both services from their own repositories, so clone the three side by side:

```bash
git clone https://github.com/shortly-org/dashboard-service.git
git clone https://github.com/shortly-org/redirect-service.git
git clone https://github.com/shortly-org/infra.git
```

```bash
cd infra/local
docker compose up --build -d
docker compose ps          # wait until dashboard-api, keycloak, kafka, postgres are healthy
```

| What | Where |
| --- | --- |
| Redirect | http://localhost:8080/{code} (set `REDIRECT_HOST_PORT` in `.env` if 8080 is taken) |
| Dashboard API | http://localhost:8081/api/v1/links — Swagger UI at http://localhost:8081/swagger-ui/index.html (Authorize: log in as `alice` or `bob`) |
| Keycloak | http://localhost:8083 (admin `admin`/`admin`; realm `shortly`; users `alice`/`alice`, `bob`/`bob`) |
| Dashboard API actuator | http://localhost:8085/actuator/health |
| Redirect actuator | http://localhost:8084/actuator/health |
| Kafka from the host | `localhost:9094` (topics are created by the one-shot `kafka-init` service; auto-creation is off) |
| Postgres from the host | `localhost:5433` (superuser `shortly`/`shortly`, schema owner `dashboard_owner`/`dashboard_owner`; set `POSTGRES_HOST_PORT` in `.env` to change) |

## Configuration

The compose file sets the same environment variables the Helm chart does, pointed at the local
containers: `DATABASE_HOST` / `DATABASE_REPLICA_HOST` / `DATABASE_PRIMARY_HOST` (`postgres`),
`DATABASE_USER` / `DATABASE_PASSWORD` (the service's own role), `DATABASE_MIGRATION_USER` /
`DATABASE_MIGRATION_PASSWORD` (`dashboard_owner`), `KAFKA_BOOTSTRAP_SERVERS` (`kafka:9092`, `PLAINTEXT`),
`KEYCLOAK_SERVER_URL` (`http://localhost:8083`, the issuer browsers see) and `KEYCLOAK_INTERNAL_URL`
(`http://keycloak:8083`, where the API fetches keys). The deployed environment's values live in
each service's `charts/values.production.yaml`.

**Database roles:** the Postgres container creates them from each service's
`local/database-roles.sql` (the dashboard's first, then the redirect's login, a member of the
dashboard's `link_reader`), standing in for the infrastructure that creates them in real
environments. Postgres runs these files only on an empty data volume: after one changes, reset the
volume with `docker compose down -v`.

**Datadog:** the images contain the production tracer, but there is no agent on a laptop, so every
application container sets `DD_TRACE_ENABLED=false` (and profiling, Data Streams, remote
configuration and telemetry off) through one YAML anchor, `x-datadog-off`.

## Demo

```bash
TOKEN=$(curl -s -d 'client_id=shortly-dashboard&grant_type=password&username=alice&password=alice' \
  http://localhost:8083/realms/shortly/protocol/openid-connect/token | jq -r .access_token)
AUTH="Authorization: Bearer $TOKEN"
```

1. **Create a link** → `201`, note the `code`.

   ```bash
   CODE=$(curl -s -H "$AUTH" -H 'Content-Type: application/json' \
     -d '{"targetUrl":"https://example.com/spring"}' http://localhost:8081/api/v1/links | jq -r .code)
   echo "$CODE"
   ```

2. **Follow it** → `302`, `Location: https://example.com/spring`, `Cache-Control: private, no-store`.

   ```bash
   curl -i -H 'CloudFront-Viewer-Country: CH' -H 'Referer: https://t.co/x' "http://localhost:8080/$CODE"
   ```

3. **Stats** (counted per UTC day, as each batch of clicks arrives, so give it a few seconds, and
   re-run the summary until `clicks` shows the count):

   ```bash
   curl -s -H "$AUTH" "http://localhost:8081/api/v1/links/$CODE/stats/summary" | jq
   curl -s -H "$AUTH" "http://localhost:8081/api/v1/links/$CODE/stats/countries" | jq   # CH
   curl -s -H "$AUTH" "http://localhost:8081/api/v1/links/$CODE/stats/referrers" | jq   # t.co
   curl -s -H "$AUTH" "http://localhost:8081/api/v1/stats/summary" | jq   # all your links
   curl -s -H "$AUTH" "http://localhost:8081/api/v1/stats/links" | jq     # your top links
   ```

4. **Deactivate** → `200`; within a second the redirect answers `410` with the "disabled" page.

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X PUT -H "$AUTH" -H 'Content-Type: application/json' \
     -d '{"status":"INACTIVE"}' "http://localhost:8081/api/v1/links/$CODE/status"
   sleep 1; curl -i "http://localhost:8080/$CODE" | head -1
   ```

5. **Reactivate, then delete** → `302` again, then `204`; the redirect answers `404`; the link still
   lists under `?status=DELETED` and its stats still read.

   ```bash
   curl -s -X PUT -H "$AUTH" -H 'Content-Type: application/json' -d '{"status":"ACTIVE"}' \
     "http://localhost:8081/api/v1/links/$CODE/status" > /dev/null
   sleep 1; curl -s -o /dev/null -w '%{http_code}\n' "http://localhost:8080/$CODE"        # 302
   curl -s -o /dev/null -w '%{http_code}\n' -X DELETE -H "$AUTH" "http://localhost:8081/api/v1/links/$CODE"  # 204
   sleep 1; curl -s -o /dev/null -w '%{http_code}\n' "http://localhost:8080/$CODE"        # 404
   curl -s -H "$AUTH" 'http://localhost:8081/api/v1/links?status=DELETED' | jq '.items[].code'
   curl -s -H "$AUTH" "http://localhost:8081/api/v1/links/$CODE/stats/summary" | jq
   ```

6. **Kafka down** — redirects keep answering; the redirect holds the clicks until Kafka is back,
   and they then land in the stats. First a second link, followed once so it is cached:

   ```bash
   CODE2=$(curl -s -H "$AUTH" -H 'Content-Type: application/json' \
     -d '{"targetUrl":"https://example.com/outage"}' http://localhost:8081/api/v1/links | jq -r .code)
   curl -s -o /dev/null -w '%{http_code}\n' "http://localhost:8080/$CODE2"   # 302, and now cached
   docker compose stop kafka
   curl -s -o /dev/null -w '%{http_code}\n' "http://localhost:8080/$CODE2"   # 302
   docker compose start kafka
   ```

7. **Postgres down** — a code already in the cache keeps redirecting (10-minute TTL, 1 s fallback
   once the feed is stale); an unknown code gets `503 Retry-After: 1`.

   ```bash
   docker compose stop postgres
   curl -s -o /dev/null -w '%{http_code}\n' "http://localhost:8080/$CODE2"   # 302
   docker compose start postgres
   ```

## Looking inside

```bash
docker compose logs -f redirect                         # the redirect's application log
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic clicks --from-beginning --property print.key=true
curl -s http://localhost:8084/actuator/prometheus | grep shortly_
docker compose exec postgres psql -U shortly -c 'select code, status, version, change_seq from link_snapshot order by change_seq desc limit 5'
```

Tear down with `docker compose down -v`.
