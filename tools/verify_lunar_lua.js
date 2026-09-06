// 交叉验证：从 main.lua 提取 lunarInfo 表 + 逐行移植算法（Lua 1-based 索引 y-1899），
// 与 tools/verify_lunar.py（0-based）的锚点结果比对。防"跨语言索引基数"回归。
const fs = require('fs');
const src = fs.readFileSync('D:\\新药申请\\weatherdash-koreader\\koplugin\\Weatherdash.koplugin\\main.lua', 'utf8');

// 1) 提取 lunarInfo 表（局部函数前的大括号块），抓全部 0x 字面量
const m = src.match(/local lunarInfo\s*=\s*\{([\s\S]*?)\n\}/);
if (!m) { console.error('FAIL: cannot find lunarInfo table'); process.exit(1); }
const nums = [...m[1].matchAll(/0x([0-9a-fA-F]+)/g)].map(x => parseInt(x[1], 16));
if (nums.length !== 201) { console.error('FAIL: table size', nums.length); process.exit(1); }
if (nums[0] !== 0x04bd8 || nums[200] !== 0x0d520) { console.error('FAIL: table head/tail mismatch'); process.exit(1); }

// 2) 查表：JS array 是 0-based（第0项=1900年），与 Lua table 1-based(lunarInfo[y-1899])
//    指向同一物理位置 —— JS 里必须写 y-1900。曾误写 y-1899 → 取到下一年数据 → 整月偏移。
const lInfo = y => nums[y - 1900] ?? nums[y > 2100 ? 200 : 0];

function lYearDays(y){let s=348;for(let mo=1;mo<=12;mo++){const b=1<<(16-mo);if(lInfo(y)&b)s++;}const lp=lInfo(y)&0xf;if(lp>0)s+=(lInfo(y)&0x10000)?30:29;return s;}
function leapMonth(y){return lInfo(y)&0xf;}
function leapDays(y){return leapMonth(y)===0?0:((lInfo(y)&0x10000)?30:29);}
function monthDays(y,mo){return (lInfo(y)&(1<<(16-mo)))?30:29;}

const DAY = 86400000;
function daysFrom(yr,mo,dy, base){ return Math.round((Date.UTC(yr,mo-1,dy)-Date.UTC(base[0],base[1]-1,base[2]))/DAY); }
const BASE=[1900,1,31], GZBASE=[1899,12,22]; // 甲子日基准（1949-10-01=甲子 验证；旧值 12-19 偏移 3 位）

function solar2lunar(y,mo,d){
  let offset=daysFrom(y,mo,d,BASE);
  let i=1900, temp=0;
  while(i<2101 && offset>0){ temp=lYearDays(i); offset-=temp; i+=1; }
  if(offset<0){ offset+=temp; i-=1; }
  const year=i; let leap=leapMonth(year), isLeap=false, month=1;
  while(month<13 && offset>0){
    if(leap>0 && month===(leap+1) && !isLeap){ month-=1; isLeap=true; temp=leapDays(year); }
    else temp=monthDays(year,month);
    if(isLeap && month===(leap+1)) isLeap=false;
    offset-=temp; month+=1;
  }
  if(offset===0 && leap>0 && month===leap+1){ if(isLeap) isLeap=false; else { isLeap=true; month-=1; } }
  if(offset<0){ offset+=temp; month-=1; }
  return {year, month, day:offset+1, isLeap};
}
const GAN=['甲','乙','丙','丁','戊','己','庚','辛','壬','癸'];
const ZHI=['子','丑','寅','卯','辰','巳','午','未','申','酉','戌','亥'];
const NM=['正月','二月','三月','四月','五月','六月','七月','八月','九月','十月','十一月','腊月'];
function lunarText(l){
  const mm=(l.isLeap?'闰':'')+NM[l.month-1]; const n=l.day;
  const s1=['日','一','二','三','四','五','六','七','八','九','十'];
  let dc; if(n<=10) dc='初'+s1[n]; else if(n<20) dc='十'+s1[n-10]; else if(n===20) dc='二十';
  else if(n<30) dc='廿'+s1[n-20]; else dc='三十';
  return mm+dc;
}
function getLunar(y,mo,d){
  const l=solar2lunar(y,mo,d);
  const dd=daysFrom(y,mo,d,GZBASE);
  const ganzhi=GAN[((dd%10)+10)%10]+ZHI[((dd%12)+12)%12];
  const yg=GAN[((l.year-4)%10+10)%10]+ZHI[((l.year-4)%12+12)%12];
  return { text:lunarText(l), yearGZ:yg, ganzhi };
}
// 3) 锚点（与 verify_lunar.py 相同）
const TESTS=[
  [1900,1,31,'正月初一','庚子'],[2024,2,10,'正月初一','甲辰'],[2025,1,29,'正月初一','乙巳'],
  [2026,2,17,'正月初一','丙午'],[2000,2,5,'正月初一','庚辰'],[2026,9,5,'七月廿四','丙午'],
  [2023,3,22,'闰二月初一','癸卯'],[2020,5,23,'闰四月初一','庚子'],[2024,4,9,'三月初一','甲辰'],
  [2026,7,7,'五月廿三','丙午'],[1996,2,19,'正月初一','丙子'],[2049,2,1,'腊月廿九','戊辰'],
  [2049,2,2,'正月初一','己巳'],
];
let fail=0;
for(const [y,mo,d,tex,gz] of TESTS){
  const L=getLunar(y,mo,d);
  const ok=L.text===tex&&L.yearGZ===gz;
  if(!ok) fail++;
  console.log((ok?'OK  ':'FAIL')+` ${y}-${String(mo).padStart(2,'0')}-${String(d).padStart(2,'0')} -> ${L.yearGZ}年 ${L.text}  (期望 ${gz}年 ${tex})`);
}
// 日干支锚点（防基准日回归；1949-10-01=甲子 为铁锚）
const DAYGZ=[[1949,10,1,'甲子'],[2000,1,1,'戊午'],[2026,9,5,'壬午'],[2026,9,6,'癸未']];
for(const [y,mo,d,gz] of DAYGZ){
  const L=getLunar(y,mo,d);
  const ok=L.ganzhi===gz;
  if(!ok) fail++;
  console.log((ok?'OK  ':'FAIL')+` 日干支 ${y}-${String(mo).padStart(2,'0')}-${String(d).padStart(2,'0')} -> ${L.ganzhi} (期望 ${gz})`);
}
console.log('----------------------------------------');
console.log(fail===0?'全部通过 (Lua 1-based 索引)':fail+' 项失败');
process.exit(fail?1:0);
