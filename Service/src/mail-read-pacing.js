// Gmail's May 2026 units: full bodies cost more than metadata. Keep reads below
// 4,500 units/minute per Google identity, leaving headroom under the 6,000 limit.
// Existing Workers rate-limit bindings count requests per location, not weighted
// globally shared work. D1's atomic UPSERT provides the cross-device reservation.
export function mailReadUnits(request) {
 const format=request.query.find(x=>x.name==='format')?.value ?? 'full';
 switch(request.resource) {
 case 'profile': case 'labels': return 1;
 case 'history': return 2;
 case 'messages': case 'drafts': return 5;
 case 'attachment': return 20;
 case 'message': case 'draft': return ['full','raw','html'].includes(format)?60:20;
 case 'thread': return format==='full'?120:40;
 default: throw new Error('unsupported mail read');
 }
}
export async function reserveMailRead(deps,sub,request) {
 const now=deps.now(), interval=Math.ceil(mailReadUnits(request)*1000/75);
 const row=await deps.db.first(`INSERT INTO mail_read_pacing(google_sub,next_at) VALUES(?,?)
 ON CONFLICT(google_sub) DO UPDATE SET next_at=MAX(mail_read_pacing.next_at,?)+?
 WHERE mail_read_pacing.next_at<=?
 RETURNING next_at`,sub,now+interval,now,interval,now+10_000);
 // Bound pending request lifetime. Rejected requests consume no reservation.
 return row?{waitMS:Math.max(0,row.next_at-interval-now)}:null;
}
