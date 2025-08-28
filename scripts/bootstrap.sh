#!/usr/bin/env bash
set -euo pipefail

# Ensure mongosh is available in PATH
export PATH="$HOME/bin:$PATH"
if ! command -v mongosh >/dev/null 2>&1; then
  mkdir -p "$HOME/bin"
  MONGOSH_VER="2.2.10"
  ARCH="x64"
  TMP="$(mktemp -d)"
  curl -fsSL -o "$TMP/mongosh.tgz" "https://downloads.mongodb.com/compass/mongosh-${MONGOSH_VER}-linux-${ARCH}.tgz"
  tar -xzf "$TMP/mongosh.tgz" -C "$TMP"
  mv "$TMP"/mongosh-*/bin/mongosh "$HOME/bin/mongosh"
  chmod +x "$HOME/bin/mongosh"
  rm -rf "$TMP"
fi

# Wait for TCP port helper
wait_for_tcp() {
  local host="$1" port="$2" tries="${3:-300}"
  for ((i=0;i<tries;i++)); do
    if (echo >"/dev/tcp/${host}/${port}") >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo "Timeout waiting for ${host}:${port}" >&2
  return 1
}

# Init cfgRS (idempotent) and wait primary inside mongosh
wait_for_tcp cfg1 27019
mongosh --quiet --host cfg1:27019 <<'JS'
try { rs.status() } catch (e) {
  rs.initiate({
    _id: "cfgRS",
    configsvr: true,
    members: [ { _id: 0, host: "cfg1:27019" } ]
  });
}
for (let i=0;i<300;i++){ try{ if (db.hello().isWritablePrimary) break }catch(e){} sleep(1000) }
JS

# Init shardA RS (idempotent)
wait_for_tcp sharda1 27018
mongosh --quiet --host sharda1:27018 <<'JS'
try { rs.status() } catch (e) {
  rs.initiate({
    _id: "shardA",
    members: [
      { _id: 0, host: "sharda1:27018", priority: 2 },
      { _id: 1, host: "sharda2:27018", priority: 1 },
      { _id: 2, host: "sharda3:27018", priority: 0 }
    ]
  });
}
for (let i=0;i<300;i++){ try{ if (db.hello().isWritablePrimary) break }catch(e){} sleep(1000) }
JS

# Init shardB RS (idempotent)
wait_for_tcp shardb1 27018
mongosh --quiet --host shardb1:27018 <<'JS'
try { rs.status() } catch (e) {
  rs.initiate({
    _id: "shardB",
    members: [
      { _id: 0, host: "shardb1:27018", priority: 2 },
      { _id: 1, host: "shardb2:27018", priority: 1 },
      { _id: 2, host: "shardb3:27018", priority: 0 }
    ]
  });
}
for (let i=0;i<300;i++){ try{ if (db.hello().isWritablePrimary) break }catch(e){} sleep(1000) }
JS

# Wire shards via mongos, enable sharding and shard the collection
wait_for_tcp mongos 27017
mongosh --quiet --host mongos:27017 <<'JS'
function shardIds(){ try { return sh.status().shards.map(s=>s._id) } catch(e){ return [] } }
const have = new Set(shardIds());
if (!have.has("shardA")) sh.addShard("shardA/sharda1:27018,sharda2:27018,sharda3:27018");
if (!have.has("shardB")) sh.addShard("shardB/shardb1:27018,shardb2:27018,shardb3:27018");

try { sh.enableSharding("demo") } catch(e) {}
const ns = "demo.users";
const meta = db.getSiblingDB("config").collections.findOne({_id: ns});
if (!meta || meta.dropped) {
  sh.shardCollection(ns, { userId: "hashed" });
}
JS

# Seed data (idempotent)
mongosh --quiet --host mongos:27017 "$(dirname "$0")/seed.js" || true
echo "bootstrap done"


