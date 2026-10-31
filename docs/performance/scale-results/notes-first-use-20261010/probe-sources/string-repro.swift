import Foundation
let texts=["Café needle", "NEEDLE\0tail", "مراجعة needle", "顧客との打ち合わせ", "Straße", "İstanbul", "A \"quote\" here", "percent %_wild", "a\nbc needle", "résumé", "ﬁle", "a😃b", "x\u{1}needle", "foo bar", "foo-bar", "foo_bar", "a  b", "a.b"]
let queries=["needle","NEEDLE","ordinary","missing","ne","Café","quote","\"quote\"","%_wild","\0","needle\0","Istanbul","STRASSE","file","foo bar","foo-bar","foo_bar","a  b","a.b","打ち合わせ","مراجعة"]
for q in queries {
 for t in texts {
  print("checking",t.debugDescription,q.debugDescription);fflush(stdout)
  print(t.localizedCaseInsensitiveContains(q));fflush(stdout)
 }
}
