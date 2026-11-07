// GGUFInfo parser test. Built in CI together with Sources/llmctl/GGUFInfo.swift:
//   python3 make_fixtures.py <dir> && swiftc ../../Sources/llmctl/GGUFInfo.swift main.swift && ./main <dir>
import Foundation

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "fixtures"
var failures = 0

func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond {
        print("ok    \(name)")
    } else {
        print("FAIL  \(name) \(detail())")
        failures += 1
    }
}

let dense = GGUFInfo.read(path: "\(dir)/dense.gguf")
check("dense: parsed past large tokenizer", dense?.architecture == "llama" && dense?.blockCount == 32)
check("dense: 32 layers x 8 KV heads", dense?.totalKVHeads == 256, "got \(String(describing: dense?.totalKVHeads))")
check("dense: key length", dense?.effectiveKeyLength == 128)
check("dense: context length", dense?.contextLength == 131072)
check("dense: no MTP", dense?.supportsMTP == false)
check("dense: exact", dense?.isApproximate == false)

let mtp = GGUFInfo.read(path: "\(dir)/qwen35_mtp.gguf")
check("qwen35 MTP: 17 attention layers x 4 heads", mtp?.totalKVHeads == 68, "got \(String(describing: mtp?.totalKVHeads))")
check("qwen35 MTP: nextn layers", mtp?.nextnPredictLayers == 1)
check("qwen35 MTP: nextn tensors found", mtp?.hasNextnTensors == true)
check("qwen35 MTP: supportsMTP", mtp?.supportsMTP == true)

let nomtp = GGUFInfo.read(path: "\(dir)/qwen35_nomtp.gguf")
check("qwen35 stripped: nextn tensors absent", nomtp?.hasNextnTensors == false)
check("qwen35 stripped: no MTP", nomtp?.supportsMTP == false)
check("qwen35 stripped: default interval 4 -> 68", nomtp?.totalKVHeads == 68, "got \(String(describing: nomtp?.totalKVHeads))")

let perLayer = GGUFInfo.read(path: "\(dir)/perlayer.gguf")
check("per-layer array: 2 layers x 8", perLayer?.totalKVHeads == 16, "got \(String(describing: perLayer?.totalKVHeads))")
check("per-layer: key length from embedding/heads", perLayer?.effectiveKeyLength == 128)

let recr = GGUFInfo.read(path: "\(dir)/recurrent.gguf")
check("recurrent_layers: 2 attention layers x 8", recr?.totalKVHeads == 16, "got \(String(describing: recr?.totalKVHeads))")
check("sliding window -> approximate", recr?.isApproximate == true)

check("not a GGUF -> nil", GGUFInfo.read(path: "\(dir)/notgguf.gguf") == nil)
check("missing file -> nil", GGUFInfo.read(path: "\(dir)/does-not-exist.gguf") == nil)

if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("all GGUF parser checks passed")
