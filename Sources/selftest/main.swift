import Foundation
import DecanterKit

let args = Array(CommandLine.arguments.dropFirst())
let t = Harness()

let wantAll = args.isEmpty || args.contains("all")
if wantAll || args.contains("unit")    { runUnitTests(t); runVideoDetectionTests(t); runExecutablePickerTests(t) }
if wantAll || args.contains("abuse")   { runAbuseTests(t) }
if wantAll || args.contains("stress")  { runStressTests(t) }
if wantAll || args.contains("saves")   { runSavesTests(t) }
if wantAll || args.contains("schema")  { runSchemaTests(t) }
if wantAll || args.contains("kb")      { runKnowledgeTests(t) }
if wantAll || args.contains("fonts")   { runFontTests(t) }
if wantAll || args.contains("reap")    { runReaperTests(t) }
if wantAll || args.contains("dxvk")    { runDXVKTests(t) }
if wantAll || args.contains("mods")    { runModLogTests(t) }
if wantAll || args.contains("stop")    { runStopScopeTests(t) }
if wantAll || args.contains("noise")   { runSaveNoiseTests(t) }
if wantAll || args.contains("explain") { runModExplainTests(t) }
if wantAll || args.contains("verbs")   { runRecipeVerbTests(t) }
if wantAll || args.contains("bench")   { runBenchTests(t) }
if wantAll || args.contains("repair")  { runRepairTests(t) }
if wantAll || args.contains("endorse") { runEndorsementTests(t) }
if wantAll || args.contains("verdict") { runVerdictTests(t) }
if wantAll || args.contains("metal")   { runMetalHostingTests(t); runDXMTTests(t); runD3D12EvidenceTests(t) }
if wantAll || args.contains("fwd")     { runForwardCompatTests(t); runUnknownCaseTests(t) }
if wantAll || args.contains("docs")    { runDocsTests(t) }
if wantAll || args.contains("docs")    { runHygieneTests(t) }
if wantAll || args.contains("docs")    { runClassificationTests(t) }
if wantAll || args.contains("docs")    { runSurfacingTests(t) }
if wantAll || args.contains("docs")    { runRealLogTests(t) }
if wantAll || args.contains("docs")    { runCLIDocsTests(t) }
if wantAll || args.contains("docs")    { runMarkdownTests(t) }
if wantAll || args.contains("exes")    { runExecutableClassifyTests(t) }
if wantAll || args.contains("exes")    { runExecutableStateTests(t) }
if wantAll || args.contains("launch")  { runLaunchTests(t) }
if wantAll || args.contains("setup")   { runAcquisitionTests(t) }
if wantAll || args.contains("setup")   { runDiskImageParseTests(t) }
if wantAll || args.contains("setup")   { runReadinessTests(t) }
if wantAll || args.contains("setup")   { runSetupOrderTests(t) }

exit(t.summary())
