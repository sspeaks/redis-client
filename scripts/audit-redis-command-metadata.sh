#!/usr/bin/env bash
set -euo pipefail

readonly REDIS_COMMIT=9913c926510755fa0d241658f550338a02258edb
readonly REDIS_REPOSITORY=https://github.com/redis/redis.git
readonly SOURCE=https://raw.githubusercontent.com/redis/redis/"$REDIS_COMMIT"/src/commands

actual=$(git ls-remote "$REDIS_REPOSITORY" refs/tags/7.2.12 | awk '{print $1}')
test "$actual" = "$REDIS_COMMIT"

for command in get set memory rename zunion xread eval object geosearch georadius; do
  curl --fail --silent --show-error "$SOURCE/$command.json" >/dev/null
done

echo "Redis OSS 7.2.12 command JSON verified at $REDIS_COMMIT"
