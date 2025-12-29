.PHONY: qa qa-cold qa-ci up down logs ps

qa:
	./qa-run.sh

qa-cold:
	./qa-run.sh --coldstart

qa-ci:
	./qa-run.sh --ci --coldstart

up:
	docker compose up -d

down:
	docker compose down --remove-orphans

ps:
	docker compose ps

logs:
	docker compose logs --tail=200
