import XCTest
@testable import InstrumentCore
final class NativeRateTests: XCTestCase {
 func testBothRates() throws {
  for (version,rate) in [(UInt8(1),48000),(UInt8(2),96000),(UInt8(3),128000)] {
   var p=[UInt8](repeating:0,count:64);p[0]=version;p[1]=2;p[2]=1
   p.replaceSubrange(24..<32,with:LE.bytes(UInt64(rate*10)))
   let s=try LoopInfo(p);XCTAssertEqual(Double(s.length)/s.sampleRate,10)
  }
  var p=[UInt8](repeating:0,count:64);p[0]=4;XCTAssertThrowsError(try LoopInfo(p))
 }
}
