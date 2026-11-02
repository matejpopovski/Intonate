import Foundation

// Reproduces everything under results/ that does not need a simulator.
//
//   swift run -c release --package-path Packages/IntonateCore intonate-bench <command> [--out results]
//
// Commands: accuracy, comparison, threshold, latency, speed, vocadito <data folder>, all

var arguments = Array(CommandLine.arguments.dropFirst())
var outputPath = "results"
if let flag = arguments.firstIndex(of: "--out"), flag + 1 < arguments.count {
    outputPath = arguments[flag + 1]
    arguments.removeSubrange(flag...(flag + 1))
}
let output = URL(fileURLWithPath: outputPath)

guard let command = arguments.first else {
    print("usage: intonate-bench accuracy|comparison|threshold|latency|speed|all|vocadito <folder> [--out dir]")
    exit(2)
}

switch command {
case "accuracy":
    try runAccuracy(output: output)
case "comparison":
    try runComparison(output: output)
case "threshold":
    try runThreshold(output: output)
case "latency":
    try runLatency(output: output)
case "speed":
    try runSpeed(output: output)
case "vocadito":
    guard arguments.count > 1 else {
        print("usage: intonate-bench vocadito <folder containing Audio and Annotations>")
        exit(2)
    }
    try runVocadito(root: URL(fileURLWithPath: arguments[1]), output: output)
case "all":
    try runAccuracy(output: output)
    try runComparison(output: output)
    try runThreshold(output: output)
    try runLatency(output: output)
    try runSpeed(output: output)
default:
    print("unknown command \(command)")
    exit(2)
}
