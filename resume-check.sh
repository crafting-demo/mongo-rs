#!/usr/bin/env bash
# resume-check.sh
#
# Verifies the sharded cluster is healthy after a sandbox *resume*.
# Checks:
#   1) mongos is reachable and lists both shards with 3 members each
#   2) shardA and shardB replica sets have a PRIMARY and ≥1 SECONDARY
#   3) demo.users is marked sharded in config metadata
#   4) demo.users has data (count > 0)
# Optional (non-fatal): shows chunk ownership across shards.
#
# Usage:
#   bash resume-check.sh
#   MONGODB_URI=mongodb://mongos:27017/admin bash resume-check.sh

set -euo pipefail

URI="${MONGODB_URI:-mongodb://mongos:27017/admin}"
MONGOSH="${MONGOSH_BIN:-mongosh}"   # override if needed

pass(){ echo -e "✅ $*"; }
fail(){ echo -e "❌ $*"; exit 2; }

step(){
  local name="$1"; shift
  echo -e "\n— $name"
  if "$@"; then pass "$name"; else fail "$name"; fi
}

# 1) Router & shard membership visible
check_router(){
  "$MONGOSH" --quiet "$URI" <<'JS' | sed -e 's/\r$//'
(function(){
  try{
    const res = db.adminCommand({listShards:1});
    const shards = (res && res.shards) || [];
    const idx = Object.fromEntries(shards.map(x => [x._id, x.host]));
    function memberCount(hostStr){
      // e.g. "shardA/sharda1:27018,sharda2:27018,sharda3:27018"
      const parts = String(hostStr||'').split('/');
      if (parts.length < 2) return 0;
      return parts[1].split(',').filter(Boolean).length;
    }
    const a = memberCount(idx["shardA"]);
    const b = memberCount(idx["shardB"]);
    if (a === 3 && b === 3) quit(0); else quit(3);
  }catch(e){ quit(4); }
})();
JS
}

# 2) shardA RS health (PRIMARY + at least one SECONDARY)
check_shardA_rs(){
  "$MONGOSH" --quiet --host sharda1:27018 <<'JS' | sed -e 's/\r$//'
(function(){
  try{
    const m = rs.status().members||[];
    const prim = m.filter(x=>x.stateStr==="PRIMARY").length;
    const secs = m.filter(x=>x.stateStr==="SECONDARY").length;
    if (prim===1 && secs>=1) quit(0); else quit(5);
  }catch(e){ quit(6); }
})();
JS
}

# 3) shardB RS health (PRIMARY + at least one SECONDARY)
check_shardB_rs(){
  "$MONGOSH" --quiet --host shardb1:27018 <<'JS' | sed -e 's/\r$//'
(function(){
  try{
    const m = rs.status().members||[];
    const prim = m.filter(x=>x.stateStr==="PRIMARY").length;
    const secs = m.filter(x=>x.stateStr==="SECONDARY").length;
    if (prim===1 && secs>=1) quit(0); else quit(7);
  }catch(e){ quit(8); }
})();
JS
}

# 4) demo.users is sharded in config metadata
check_collection_sharded(){
  "$MONGOSH" --quiet "$URI" <<'JS' | sed -e 's/\r$//'
(function(){
  try{
    const c = db.getSiblingDB("config").collections.findOne({_id:"demo.users"});
    if (c && c.dropped !== true) quit(0); else quit(9);
  }catch(e){ quit(10); }
})();
JS
}

# 5) demo.users has data
check_demo_count(){
  "$MONGOSH" --quiet "$URI" <<'JS' | sed -e 's/\r$//'
(function(){
  try{
    const n = db.getSiblingDB("demo").users.countDocuments();
    print("demo.users count:", n);
    if (n > 0) quit(0); else quit(11);
  }catch(e){ quit(12); }
})();
JS
}

# (Optional) show chunk distribution (non-fatal)
show_chunk_split(){
  "$MONGOSH" --quiet "$URI" <<'JS' | sed -e 's/\r$//'
try{
  const rows = db.getSiblingDB("config").chunks.aggregate([
    { $match: { ns: "demo.users" } },
    { $group: { _id: "$shard", n: { $sum: 1 } } },
    { $sort: { _id: 1 } }
  ]).toArray();
  printjson(rows);
}catch(e){
  print("could not read chunk distribution:", e);
}
JS
}

echo "Resume health check against URI: $URI"

step "Router sees both shards with 3 members each"    check_router
step "shardA replica set has PRIMARY + SECONDARY(s)"  check_shardA_rs
step "shardB replica set has PRIMARY + SECONDARY(s)"  check_shardB_rs
step "demo.users is sharded in config metadata"       check_collection_sharded
step "demo.users has documents"                        check_demo_count

echo -e "\n(Info) Chunk ownership:"
show_chunk_split

echo -e "\n✅ All resume checks passed."