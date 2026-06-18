# WordPress layer

WordPress itself is pulled from the official `wordpress:6.7-php8.3-fpm` image at
runtime; there is no application code in this repo, by design. The repo is about
the *infrastructure* around WordPress, which is generic and reusable across any
PHP front-controller app.

## Object cache drop-in (one step after first boot)

The full-page cache (nginx to Redis) works out of the box. To also give the
**live / cache-miss** path a Redis object cache (so even uncached renders avoid
repeating expensive SQL), install the Redis Object Cache drop-in once:

```bash
docker compose exec php bash -lc '
  curl -L https://downloads.wordpress.org/plugin/redis-cache.latest-stable.zip -o /tmp/rc.zip &&
  cd /var/www/html/wp-content/plugins && unzip -o /tmp/rc.zip &&
  wp plugin activate redis-cache --allow-root &&
  wp redis enable --allow-root
'
```

`WP_REDIS_HOST=redis` is already wired in `docker-compose.yml`, so the plugin
connects with no further config. After this, `wp redis status` should report a
live connection, and the object cache and full-page cache share one Redis.
