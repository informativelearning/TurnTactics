// Pure local host engine. Never use client state as multiplayer authority.
export const costs={move:1,attack:1,give:1,shield:2,range:2,remove:0};
export function createGame(names,size=names.length-1){
 if(names.length<5||names.length>20)throw Error('Use 5–20 players.');
 if(!Number.isInteger(size)||size<3||size>24||size*size<names.length)throw Error('Invalid board size.');
 if(names.some(n=>!n.trim())||new Set(names).size!==names.length)throw Error('Use unique, nonempty names.');
 const cells=Array.from({length:size*size},(_,i)=>i);
 for(let i=cells.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[cells[i],cells[j]]=[cells[j],cells[i]];}
 return {version:1,day:1,size,closed:false,winner:null,players:names.map((name,i)=>({id:i,name,x:cells[i]%size,y:Math.floor(cells[i]/size),hearts:3,points:1,range:2,shield:false,alive:true})),votes:{},log:['Game started. Each player received 1 point.']};
}
export function act(state,id,type,target){
 const s=structuredClone(state),p=s.players.find(p=>p.id===id);
 if(s.winner!==null)throw Error('The game has ended.');
 if(s.closed)throw Error('Actions are closed for this prototype day.');
 if(!p?.alive)throw Error('Select a living player.');
 if(!(type in costs))throw Error('Unknown action.');
 if(p.points<costs[type])throw Error('Not enough points.');
 const q=s.players.find(p=>p.id===target);
 if(type==='move'){
  const [dx,dy]=({up:[0,-1],down:[0,1],left:[-1,0],right:[1,0]})[target]||[];
  if(dx===undefined)throw Error('Choose a direction.');
  const x=p.x+dx,y=p.y+dy;
  if(x<0||y<0||x>=s.size||y>=s.size||s.players.some(q=>q.alive&&q.x===x&&q.y===y))throw Error('That tile is blocked.');
  p.x=x;p.y=y;
 }
 if(type==='attack'||type==='give'){
  if(!q?.alive||q.id===p.id)throw Error('Choose another living player.');
  if(Math.abs(p.x-q.x)+Math.abs(p.y-q.y)>p.range)throw Error('Target is out of range.');
  if(type==='attack'){
   if(q.shield)throw Error('Target is shielded; no points spent.');
   q.hearts--;if(q.hearts===0){q.alive=false;s.log.unshift(`${p.name} eliminated ${q.name}.`);}
  }else q.points++;
 }
 if(type==='shield'){if(p.shield)throw Error('Already shielded.');p.shield=true;}
 if(type==='range')p.range++;
 if(type==='remove')p.alive=false;
 p.points-=costs[type];
 s.log.unshift(`${p.name}: ${type}${q?' → '+q.name:type==='move'?' '+target:''}.`);
 const survivors=s.players.filter(p=>p.alive);if(survivors.length===1)s.winner=survivors[0].id;
 return s;
}
export function vote(state,voter,target){
 const s=structuredClone(state);
 if(s.winner!==null)throw Error('The game has ended.');
 if(!s.players.some(p=>p.id===voter&&!p.alive)||!s.players.some(p=>p.id===target&&p.alive))throw Error('Only eliminated players may vote for living players.');
 s.votes[voter]=target;return s;
}
export function nextDay(state){
 const s=structuredClone(state);if(s.winner!==null)throw Error('The game has ended.');
 const counts={};for(const [v,t] of Object.entries(s.votes))if(s.players.some(p=>p.id===Number(v)&&!p.alive)&&s.players.some(p=>p.id===t&&p.alive))counts[t]=(counts[t]||0)+1;
 const votes=Object.values(counts).reduce((a,b)=>a+b,0);
 const bonus=Object.keys(counts).find(id=>counts[id]>votes/2);
 s.day++;s.closed=false;
 for(const p of s.players){p.shield=false;if(p.alive)p.points+=1+(String(p.id)===bonus?1:0);}
 s.votes={};s.log.unshift(`Day ${s.day}: income awarded, shields expired${bonus!==undefined?', majority vote bonus awarded':''}.`);return s;
}
