import{createGame,act,nextDay,vote}from './engine.js';
const $=id=>document.getElementById(id),key='turn-tactics-v1';let game,actor=0;
try{const saved=JSON.parse(localStorage.getItem(key));if(saved?.version===1&&Array.isArray(saved.players)&&saved.players.length>=5&&Number.isInteger(saved.size)&&saved.size>=3&&saved.size<=24)game=saved;}catch{}
const option=(id,text)=>{const o=document.createElement('option');o.value=id;o.textContent=text;return o;};
function save(){try{localStorage.setItem(key,JSON.stringify(game));}catch{$('message').textContent='Storage unavailable. This session will not be saved.';}}
function render(){
 if(!game)return;
 const living=game.players.filter(p=>p.alive);if(!living.some(p=>p.id===actor))actor=living[0]?.id;
 const p=game.players.find(p=>p.id===actor);$('actor').replaceChildren(...living.map(p=>option(p.id,p.name)));$('actor').value=actor;
 $('target').replaceChildren(...living.filter(q=>q.id!==actor).map(q=>option(q.id,q.name)));
 $('day').textContent=`DAY ${game.day} · ${living.length} ALIVE`;
 $('status').textContent=game.winner!==null?`${game.players.find(p=>p.id===game.winner).name} wins.`:game.closed?'Actions closed · waiting for the next day.':`${game.size} × ${game.size} arena · actions open`;
 $('stats').replaceChildren(...[`${p.hearts} hearts`,`${p.points} points`,`Range ${p.range}`,p.shield?'Shield active':'No shield'].map(text=>{const s=document.createElement('span');s.textContent=text;return s;}));
 $('board').style.setProperty('--size',game.size);$('board').replaceChildren();
 for(let y=0;y<game.size;y++)for(let x=0;x<game.size;x++){
  const q=living.find(p=>p.x===x&&p.y===y),b=document.createElement('button');b.className='tile';
  if(Math.abs(p.x-x)+Math.abs(p.y-y)<=p.range)b.classList.add('inrange');
  b.setAttribute('aria-label',`Column ${x+1}, row ${y+1}${q?', '+q.name:''}`);
  if(q){b.textContent=String(q.id+1).padStart(2,'0');b.classList.add('occupied');b.title=q.name;if(q.id===actor)b.classList.add('selected');if(q.shield)b.classList.add('shielded');b.onclick=()=>{actor=q.id;render();};}else b.disabled=true;
  $('board').append(b);
 }
 $('log').replaceChildren(...game.log.slice(0,100).map(text=>{const li=document.createElement('li');li.textContent=text;return li;}));
 $('voter').replaceChildren(...game.players.filter(p=>!p.alive).map(p=>option(p.id,p.name)));$('recipient').replaceChildren(...living.map(p=>option(p.id,p.name)));
 $('votes').textContent=`${Object.keys(game.votes).length} ballot(s) recorded this day.`;
 $('vote').disabled=!$('voter').options.length||game.winner!==null;
 document.querySelectorAll('[data-action],[data-move],#remove,#close').forEach(b=>b.disabled=game.closed||game.winner!==null);$('next').disabled=game.winner!==null;
 $('close').textContent=game.closed?'Actions closed':'Close actions';
}
function commit(fn){$('message').textContent='';try{game=fn();render();save();}catch(e){$('message').textContent=e.message;}}
$('actor').onchange=e=>{actor=Number(e.target.value);render();};
document.querySelectorAll('[data-action]').forEach(b=>b.onclick=()=>commit(()=>act(game,actor,b.dataset.action,Number($('target').value))));
document.querySelectorAll('[data-move]').forEach(b=>b.onclick=()=>commit(()=>act(game,actor,'move',b.dataset.move)));
$('remove').onclick=()=>{if(confirm('Remove this player? They can still vote.'))commit(()=>act(game,actor,'remove'));};
$('next').onclick=()=>{if(confirm('Advance one prototype day, award income and expire shields?'))commit(()=>nextDay(game));};
$('close').onclick=()=>commit(()=>({...game,closed:true}));
$('vote').onclick=()=>commit(()=>vote(game,Number($('voter').value),Number($('recipient').value)));
$('reset').onclick=()=>{$('setupError').textContent='';$('setup').showModal();};
$('names').oninput=()=>{$('size').value=Math.max(3,$('names').value.split('\n').filter(n=>n.trim()).length-1);};
$('cancelSetup').onclick=()=>{if(game)$('setup').close();};$('setup').addEventListener('cancel',e=>{if(!game)e.preventDefault();});
$('setupForm').onsubmit=e=>{e.preventDefault();try{const names=$('names').value.split('\n').map(s=>s.trim()).filter(Boolean);game=createGame(names,Number($('size').value));actor=0;$('setup').close();render();save();}catch(e){$('setupError').textContent=e.message;}};
if(game)render();else $('setup').showModal();
if('serviceWorker'in navigator)navigator.serviceWorker.register('./sw.js').catch(()=>{});
