import Foundation
import CoreGraphics
@main struct Check {
 static func main() async {
  let colors = FixturePalette.fills
  @Sendable func render(_ index:Int) -> Data {
   let space=CGColorSpaceCreateDeviceRGB()
   let context=CGContext(data:nil,width:1179,height:768,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
   context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:1179,height:768))
   for row in 0..<100 {
    context.setFillColor(colors[(row+index)%12]);context.fill(CGRect(x:Double(row)*11.7,y:0,width:8.3,height:768))
   }
   return context.makeImage()!.dataProvider!.data! as Data
  }
  let references=(0..<12).map{render($0)}
  let errors=await withTaskGroup(of:Int.self,returning:Int.self) { group in
   for worker in 0..<2 { group.addTask { var errors=0;for i in 0..<100 {if render((i+worker)%12) != references[(i+worker)%12] {errors+=1}};return errors } }
   var sum=0;for await n in group {sum+=n};return sum
  }
  print("Pure CoreGraphics concurrent failures",errors)
 }
}
