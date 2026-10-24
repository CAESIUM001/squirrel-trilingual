import AppKit
import Foundation
@MainActor final class Checks: NSObject, NSApplicationDelegate {
  var failures:[String] = []
  var count=0
  func check(_ value:Bool,_ name:String) {count+=1;if !value {failures.append(name)}}
  func applicationDidFinishLaunching(_ notification:Notification) {Task {await run()}}
  func run() async {
    let watchdog=Task {try? await Task.sleep(nanoseconds:30_000_000_000);guard !Task.isCancelled else{return};print("timeout");exit(2)}
    let translator=SquirrelSentenceTranslator.french
    check(translator.cachedTranslations(for:["不存在的未见长句"]).isEmpty,"missing glossary/cache harmless")
    let samples=["今天下午我們一起去圖書館","春天的公园里开满了美丽的鲜花","我们可以一起讨论明天的工作安排"]
    var updates:[[String:String]]=[]
    let results:[String:String]=await withCheckedContinuation { continuation in
      translator.requestBatch(samples+samples+[""],progress:{updates.append($0)}) {continuation.resume(returning:$0)}
    }
    check(results.count==3,"deduplicated bounded batch completed")
    check(updates.count==3,"one progressive update per uncached result")
    check(updates.first?[samples[0]] != nil && updates.first?.count==1,"first caller candidate prioritized")
    check(updates.enumerated().allSatisfy{$0.element.count==$0.offset+1},"cumulative progress")
    check(updates.last==results,"final progress equals completion")
    check(translator.cachedTranslations(for:samples)==results,"completed results in synchronous cache")
    var cancelledCompleted=false
    var cancelledProgress=0
    translator.requestBatch(samples,progress:{ _ in cancelledProgress+=1;translator.cancel()}) { _ in cancelledCompleted=true }
    check(cancelledProgress==1 && !cancelledCompleted,"cached callback reentrant cancellation")
    let stale=translator.requestBatch([samples[0]]) {_ in}
    let freshText="深秋的微风吹过安静的庭院"
    let fresh:[String:String]=await withCheckedContinuation {continuation in
      translator.requestBatch([freshText]) {continuation.resume(returning:$0)}
      translator.cancel(stale)
    }
    check(fresh[freshText]?.isEmpty==false,"stale identifier cannot cancel fresh request")
    let cancelSamples=["山间的小路通向一座古老的石桥","河边的柳树在微风中轻轻摇晃","我们计划周末去参观新的科学博物馆"]
    var actualProgress=0
    var actualComplete=false
    await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
      translator.requestBatch(cancelSamples,progress:{_ in
        actualProgress+=1
        translator.cancel()
        if actualProgress==1 {continuation.resume()}
      }) {_ in actualComplete=true}
    }
    try? await Task.sleep(nanoseconds:200_000_000)
    check(actualProgress==1 && !actualComplete,"cancelled model job emits no stale callbacks")
    check(translator.cachedTranslations(for:[cancelSamples[0]])[cancelSamples[0]] != nil,"partial result retained after cancellation")
    let independent:(String?,[String:String])=await withCheckedContinuation {continuation in
      var english:String?;var french:[String:String]=[:];var e=false;var f=false
      SquirrelSentenceTranslator.shared.request("今天下午我們一起去圖書館") {value in english=value;e=true;if f{continuation.resume(returning:(english,french))}}
      translator.requestBatch(["我很高兴今天能够认识你"]) {value in french=value;f=true;if e{continuation.resume(returning:(english,french))}}
    }
    check(independent.0?.isEmpty==false && independent.1.count==1,"English/French requests independent")
    watchdog.cancel()
    let result:[String:Any]=["assertions":count,"failures":failures,"model_requests":"real Apple offline Translation","first_progress_count":updates.first?.count ?? 0]
    print(String(data:try! JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)
    fflush(stdout);exit(failures.isEmpty ? 0:1)
  }
}
@main struct Entry {@MainActor static func main(){let app=NSApplication.shared;app.setActivationPolicy(.accessory);let delegate=Checks();app.delegate=delegate;withExtendedLifetime(delegate){app.run()}}}
