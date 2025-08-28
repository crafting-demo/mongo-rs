const dbName = "demo", coll = "users";
const dbDemo = db.getSiblingDB(dbName);
const markerColl = dbDemo.getCollection("__bootstrap");
if (!markerColl.findOne({_id: "loaded"})) {
  const N = 2000, ops = [];
  for (let i = 0; i < N; i++) {
    ops.push({insertOne:{document:{
      _id:i,
      userId:i,
      name:`User ${i}`,
      email:`user${i}@example.com`,
      createdAt:new Date()
    }}});
  }
  dbDemo[coll].bulkWrite(ops,{ordered:false});
  markerColl.insertOne({_id: "loaded", at: new Date()});
  print(`Loaded ${N} docs`);
} else {
  print("Test data present; skipping");
}
print("Count:", dbDemo[coll].countDocuments());


