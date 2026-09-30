// 一次性应用官方答案校准（幂等）。此脚本之后，verify-official.js 只读复核。
const os=require('os');const {DatabaseSync}=require('node:sqlite');
const db=new DatabaseSync(os.homedir()+'/kidreminder/kidreminder.db');
const PK='rulang-2025';
const qid=(s)=>db.prepare('SELECT id FROM epaper_questions WHERE paper_key=? AND paper_seq=?').get(PK,s).id;
let n=0;
const setPoint=(seq,pseq,desc,kw)=>{
  const r=db.prepare('UPDATE epaper_mark_points SET description=?, keywords=? WHERE question_id=? AND seq=?')
    .run(desc, JSON.stringify(kw), qid(seq), pseq);
  if(!r.changes) throw new Error(`Q${seq}.${pseq} 未更新`);
  n++;
};
const setAnswer=(seq,v)=>{
  const r=db.prepare('UPDATE epaper_questions SET correct_answer=? WHERE paper_key=? AND paper_seq=?').run(v,PK,seq);
  if(!r.changes) throw new Error(`Q${seq} 未更新`);
  n++;
};

// --- 答案键纠错 ---
setAnswer(45,'persistently');                       // 官方：副词 persistently
for (const [seq,extra] of [[61,'The cheese on the plate was eaten by the mouse'],
      [62,'Had Aidah not moved away in time, the cat would have clawed her.'],
      [64,'It was with great eagerness that the children started their holiday.']]) {
  const cur=db.prepare('SELECT correct_answer FROM epaper_questions WHERE paper_key=? AND paper_seq=?').get(PK,seq).correct_answer;
  if(!cur.includes(extra)) setAnswer(seq, cur+' / '+extra);
}

// --- 收紧过松的得分点 ---
setPoint(68,1,'(a) False — Gita wondered why the ladies did not shop at the upscale supermarkets, since they thought the wet market was dirty.',
  [['false'],['did not shop','did not go','avoid','not patronise','not shop','upscale supermarket','supermarket','clean'],
   ['dirty','unhygienic','filthy','unclean','out of place']]);

setPoint(69,2,'The person who put up the post — Eileen Tan herself (not the post/photo).',
  [['the person','person who','one who','the girl who','who made','who posted','who put up','eileen tan','the author of the post']]);

setPoint(70,2,'(b) She did not believe Gita’s claim that she was there for a class project — she thought Gita was lying.',
  [['not belie','disbeliev','didnt belie','not convinced','doubt','refus'],
   ['class project','project','lying','lie','untrue']]);

setPoint(70,4,'(d) She recalled how Ramani had taken on the stall during their mother’s recovery.',
  [['taken on','took on','taken over','took over','took charge','ran the stall'],
   ['recovery','recovering','mother','mum']]);

setPoint(71,2,'(b) She used to be ashamed of working at the wet market, but she was not ashamed anymore.',
  [['ashamed','embarrassed','humiliated'],
   ['not anymore','no longer','not any more','used to','before','anymore','stopped being','no more']]);

setPoint(72,1,'They understood each other so well that they did not need words to express themselves.',
  [['understood','understand','knew'],
   ['without words','no words','did not need words','did not need to talk','did not need to say','unspoken','not need to explain','quiet actions']]);

setPoint(72,2,'They were very close and comfortable with each other — no awkwardness or tension.',
  [['close','comfortable','at ease','no awkwardness','no tension','bond','trust','good relationship']]);

// Q74(1)：官方是 "not being afraid TO TELL"。孩子的 "not being afraid OF HIDING" 是
// 双重否定、意思反了，所以 afraid 后面必须接 to，挡住 of 这类错配。
setPoint(74,1,'Not being afraid to tell her schoolmates about her background (her family working at the wet market).',
  [['not afraid to','not being afraid to','no longer afraid to','afraid to tell','dared to',
    'willing to tell','not hide','stopped hiding','no longer hid','open about','unafraid'],
   ['tell','schoolmate','friends at school','others','people','talk about','share']]);

setPoint(74,2,'Instead she was proud of it — she accepted herself rather than avoiding the truth.',
  [['proud','accept','accepted','embrace','be proud','confiden','true to herself']]);

console.log(`已应用 ${n} 处修改`);
