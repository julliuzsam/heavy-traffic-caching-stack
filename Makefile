.PHONY: up down logs bench bench-anon hitratio hitratio-log warm smoke purge clean

up:            ## Build and start the full stack
	docker compose up -d --build
	@echo "Stack up. WordPress on http://localhost:8080  (first load runs WP install)"

down:          ## Stop the stack
	docker compose down

logs:          ## Tail nginx logs with the cache-status field
	docker compose logs -f nginx

bench:         ## Mixed load test: anonymous (cacheable) + logged-in (bypass)
	k6 run load/k6-mixed.js

bench-anon:    ## Pure anonymous load test (measures peak cached throughput)
	k6 run load/k6-anon.js

smoke:         ## Quick sanity check: anon request is HIT, logged-in is BYPASS
	@echo "anon:" && curl -sI http://localhost:8080/ | grep -i x-cache-status || true
	@echo "logged-in:" && curl -sI --cookie "wordpress_logged_in_demo=1" http://localhost:8080/ | grep -i x-cache-status || true

hitratio:      ## Print the live Redis hit ratio (cumulative)
	@docker compose exec redis redis-cli INFO stats | grep -E "keyspace_(hits|misses)"

hitratio-log:  ## Hit ratio from the nginx access log (HIT/MISS/BYPASS breakdown)
	@docker compose exec nginx sh -c 'cat /var/log/nginx/access.log' | scripts/cache-hitratio.sh

warm:          ## Warm the cache from the sitemap (run after a deploy/flush)
	BASE_URL=http://localhost:8080 scripts/warm-cache.sh

purge:         ## Flush the full-page cache
	docker compose exec redis redis-cli FLUSHDB

clean:         ## Stop and remove volumes (wipes the demo DB)
	docker compose down -v

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
