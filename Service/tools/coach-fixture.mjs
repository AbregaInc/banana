// Synthetic review data only; never loaded by the deployed service.
export function coachFixture({now,healthPayload,record}) {
  const swift=ms=>ms/1000-978307200;
  const dayAt=(ago,h=0,m=0)=>{const d=new Date(now);d.setDate(d.getDate()-ago);d.setHours(h,m,0,0);return +d;};
  const dateKey=ms=>{const d=new Date(ms);return String(d.getFullYear())+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0');};
  const specs={sleepHours:[7.2,.8],restingHR:[57,5],hrv:[52,12],steps:[8500,2800],vo2Max:[44,2],respiratory:[14,1],bodyMassKg:[72,1.1],bodyFatPercentage:[.21,.008],activeEnergyKcal:[510,150],exerciseMinutes:[42,18],walkingHeartRate:[99,8],basalEnergyKcal:[1650,60],leanBodyMassKg:[57,.5],bodyMassIndex:[23.5,.3],heightMeters:[1.75,0],flightsClimbed:[9,4],walkingSpeedMetersPerSecond:[1.35,.15]};
  healthPayload.trends=Object.fromEntries(Object.entries(specs).map(([key,[base,spread]])=>[key,Array.from({length:400},(_,i)=>({date:swift(dayAt(399-i)),value:Math.round((base+Math.sin(i*1.7)*spread)*10000)/10000}))]));
  healthPayload.trends.nights=Array.from({length:120},(_,i)=>{
    const wake=dayAt(i,7,10+(i%4)*10),bed=dayAt(i+1,23,10+(i%3)*15),awake=12+(i%4)*7;
    return {night:swift(dayAt(i)),bedtime:swift(bed),wake:swift(wake),asleepMinutes:(wake-bed)/60000-awake,wakes:[{start:swift(bed+3*3600000),end:swift(bed+3*3600000+awake*60000),steps:i%2?18:0,kind:'awakeInBed',labelled:false}]};
  });
  record('food.supplement','sup-demo',{name:'Example supplement',dose:'1 tablet',hour:8,minute:0,kind:'supplement',enabled:true,note:'Fictional example for reviewing the dose log.',ingredients:['Example ingredient']});
  for(let i=0;i<21;i++){
    const logged=dayAt(i,8);
    record('food.dose','demo-dose-'+i,{supplementID:'sup-demo',day:dateKey(logged),date:logged,status:i%6===0?'skipped':'taken'});
    for(const [j,name]of ['Breakfast','Lunch','Dinner'].entries())record('food.meal','demo-meal-'+i+'-'+j,{name,date:dayAt(i,8+j*5),note:'Fictional review data.',items:[{name:['Yogurt, oats and fruit','Chicken and rice bowl','Salmon, potatoes and greens'][j],serving:'1 plate',macros:{calories:[410,620,570][j]+i%3*20,proteinGrams:[25,42,38][j],carbohydrateGrams:[50,65,48][j],fatGrams:[12,21,24][j]}}]});
    if(i%3===0)record('health.workout','demo-workout-'+i,{activity:i%2?'Outdoor run':'Strength training',start:dayAt(i,10),end:dayAt(i,10)+2700000,totalEnergy:310+i,avgHeartRate:125+i%10,...(i%2?{totalDistance:5200}:{})});
  }
}
