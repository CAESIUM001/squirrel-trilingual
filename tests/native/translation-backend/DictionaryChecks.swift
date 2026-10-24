import Foundation
@main struct Entry {
 @MainActor static func main(){
  let french=SquirrelSentenceTranslator.french
  var failures:[String]=[];var count=0
  func check(_ value:Bool,_ name:String){count+=1;if !value{failures.append(name)}}
  check(french.cachedTranslations(for:["学习"])["学习"]=="Étude","exact word dictionary")
  check(french.cachedTranslations(for:["學習"])["學習"]=="Étude","traditional simplified fallback")
  check(french.cachedTranslations(for:["圖書館"])["圖書館"]=="Bibliothèque","traditional library fallback")
  check(SquirrelSentenceTranslator.shared.cachedTranslations(for:["学习"]).isEmpty,"French dictionary isolated from English")
  check(french.cachedTranslations(for:["",String(repeating:"超",count:3000),"不在词表中的完整句子"]).isEmpty,"empty oversized and absent inputs harmless")
  for start in stride(from:0,to:1100,by:100) {let words=(start..<min(start+100,1100)).map{"测试字\($0)"};check(french.cachedTranslations(for:words).count==words.count,"fixture lookup chunk \(start)")}
  let fields=Dictionary(uniqueKeysWithValues:Mirror(reflecting:french).children.compactMap{child -> (String,Any)? in guard let label=child.label else{return nil};return(label,child.value)})
  let cache=fields["cache"] as! [String:String];let bytes=fields["cacheBytes"] as! Int
  check(cache.count<=1024,"cache bounded by entry count")
  check(bytes<=2*1024*1024 && bytes==cache.reduce(0){$0+$1.key.utf8.count+$1.value.utf8.count},"cache bytes bounded and exact")
  check(cache["测试字1099"] != nil && cache["测试字0"]==nil,"least recently used entries evicted")
  check(french.cachedTranslations(for:["學習"])["學習"]=="Étude","evicted glossary word restored synchronously")
  let output:[String:Any]=["assertions":count,"failures":failures,"cache_entries":cache.count,"cache_bytes":bytes,"dictionary":"temporary test fixture; no real user input"]
  print(String(data:try! JSONSerialization.data(withJSONObject:output,options:.sortedKeys),encoding:.utf8)!);exit(failures.isEmpty ? 0:1)
 }
}
