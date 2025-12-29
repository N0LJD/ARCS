set -e
date
docker compose version
docker --version
./admin/first-run.sh --force
curl -fsS http://127.0.0.1:8080/health >/dev/null
curl -fsS "http://127.0.0.1:8080/xml.php?callsign=W1AW" >/dev/null
curl -fsS http://127.0.0.1:8081/api/health >/dev/null
curl -fsS "http://127.0.0.1:8081/api/xml.php?callsign=W1AW" >/dev/null
echo "QA PASS"

