import{SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY}from './online-config.js';
const $=id=>document.getElementById(id);let db,room,busy=false,pending=null,timer;
let remembered='';try{remembered=localStorage.getItem('tt-online-room')||'';pending=JSON.parse(sessionStorage.getItem('tt-online-pending')||'null');}catch{}
function stashPending(value){pending=value;try{if(value)sessionStorage.setItem('tt-online-pending',JSON.stringify(value));else sessionStorage.removeItem('tt-online-pending');}catch{}}
const setText=(id,value)=>{$(id).textContent=value;};
const option=(id,name)=>{const o=document.createElement('option');o.value=id;o.textContent=name;return o;};
function message(text){setText('feedback',text);}
function render(s){room=s;$('testNotice').hidden=!s.isTest;$('fillTest').hidden=!s.isHost||s.phase!=='lobby'||s.players.length>=5;setText('roomCode',s.code);$('room').hidden=false;$('entry').hidden=true;
 setText('roomStatus',`${s.isHost?'HOST / REFEREE':'PLAYER'} · ${s.phase.toUpperCase()} · DAY ${s.day}${s.closed?' · ACTIONS CLOSED':''}`);
 const me=s.players.find(p=>p.id===s.me),alive=s.players.filter(p=>p.alive);
 $('roster').replaceChildren(...s.players.map(p=>{const li=document.createElement('li');li.textContent=`${String(p.id+1).padStart(2,'0')} · ${p.name}${p.alive?'':' · eliminated'}${p.hearts!==undefined&&s.phase!=='lobby'?` · ${p.hearts} hearts / ${p.points} points / range ${p.range}${p.shield?' / shielded':''}`:''}`;return li;}));
 $('startControls').hidden=!s.isHost||s.phase!=='lobby';$('play').hidden=s.phase==='lobby';$('hostControls').hidden=!s.isHost||s.phase!=='active';$('playerControls').hidden=s.isHost||!me?.alive||s.phase!=='active';$('voteControls').hidden=s.isHost||!me||me.alive||s.phase!=='active';
 setText('roleTitle',s.isHost?'Host desk':'Your next play');setText('myStats',me?`${me.hearts} hearts · ${me.points} points · Range ${me.range}${me.shield?' · Shield active':''}`:'Referee view · all resources visible');
 for(const id of ['target','voteTarget']){const old=$(id).value;$(id).replaceChildren(...alive.filter(p=>p.id!==s.me).map(p=>option(p.id,p.name)));if([...$(id).options].some(o=>o.value===old))$(id).value=old;}
 if(s.phase!=='lobby'){
 $('onlineBoard').style.setProperty('--size',s.size);$('onlineBoard').replaceChildren();
 for(let y=0;y<s.size;y++)for(let x=0;x<s.size;x++){
 const p=alive.find(p=>p.x===x&&p.y===y),b=document.createElement('button');b.className='tile';b.disabled=true;b.setAttribute('aria-label',`Column ${x+1}, row ${y+1}${p?', '+p.name:''}`);
 if(me?.alive&&Math.abs(me.x-x)+Math.abs(me.y-y)<=me.range)b.classList.add('inrange');
 if(p){b.textContent=String(p.id+1).padStart(2,'0');b.classList.add('occupied');b.style.opacity='1';if(p.id===s.me)b.classList.add('selected');if(p.shield)b.classList.add('shielded');}$('onlineBoard').append(b);
 }
 }
 const list=(id,items)=>$(id).replaceChildren(...items.slice(0,100).map(text=>{const li=document.createElement('li');li.textContent=text;return li;}));list('events',s.events);$('audit').hidden=!s.isHost;list('hostLog',s.hostLog);
 if(s.phase==='ended')message(`Game over. ${s.players.find(p=>p.id===s.winner)?.name||'Last survivor'} wins.`);
 updateButtons();
}
function updateButtons(){document.querySelectorAll('button').forEach(b=>{if(b.id!=='connect'&&b.id!=='retry')b.disabled=busy||!!pending;});if(room){$('start').disabled=busy||!!pending||room.players.length<5;$('fillTest').disabled=busy||!!pending||!room.isHost||room.phase!=='lobby'||room.players.length<1||room.players.length>=5;document.querySelectorAll('[data-action],[data-move],#remove').forEach(b=>b.disabled=busy||!!pending||room.closed||room.phase!=='active');}}
async function rpc(name,args){const{data,error}=await db.rpc(name,args);if(error)throw error;return data;}
async function refresh(){if(!room||busy||pending)return;try{render(await rpc('tt_view',{p_code:room.code}));setText('sync','Synced '+new Date().toLocaleTimeString());}catch{setText('sync','Connection lost. Display may be stale; actions still require server confirmation.');}}
async function send(name,args){if(busy)return;if(name==='tt_command')stashPending({name,args});busy=true;updateButtons();message('Waiting for server confirmation…');try{const s=await rpc(name,args);stashPending(null);$('retry').hidden=true;render(s);try{localStorage.setItem('tt-online-room',s.code);}catch{}message('Server confirmed.');setText('sync','Synced '+new Date().toLocaleTimeString());if(!timer)timer=setInterval(refresh,4000);}catch(e){
 // Postgres errors have a code. Transport errors may have no code: retain action UUID for safe retry.
 if(name==='tt_command'&&!e.code){stashPending({name,args});$('retry').hidden=false;message('Confirmation unavailable. Do not repeat the action. Use “Retry the same request” to safely check or complete it.');}
 else{stashPending(null);$('retry').hidden=true;message(e.message||'Request failed.');}
 }finally{busy=false;updateButtons();}}
const command=(action,extra={})=>{if(!pending&&!busy&&room)send('tt_command',{p_code:room.code,p_request:crypto.randomUUID(),p_action:action,...extra});};
$('connect').onclick=async()=>{if(db)return;$('connect').disabled=true;message('Connecting…');try{const{createClient}=await import('https://esm.sh/@supabase/supabase-js@2.49.1');db=createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY);let{data,error}=await db.auth.getSession();if(error)throw error;if(!data.session){const result=await db.auth.signInAnonymously();if(result.error)throw result.error;}
 $('connect').hidden=true;$('entry').hidden=false;setText('connectionStatus','Connected. This browser has its own player identity.');message('');if(pending){$('retry').hidden=false;message('An earlier action is awaiting confirmation. Retry the same request before acting again.');updateButtons();}if(remembered){try{const s=await rpc('tt_view',{p_code:remembered});render(s);timer=setInterval(refresh,4000);}catch{$('code').value=remembered;}}
 }catch(e){db=null;$('connect').disabled=false;message(e.message||'Connection failed. Check configuration and anonymous sign-ins.');}};
$('fillTest').onclick=()=>{if(!busy&&!pending&&room?.isHost&&confirm('Add placeholder seats? This room will permanently be marked as a test game.'))send('tt_fill_test_seats',{p_code:room.code});};
$('create').onclick=()=>send('tt_create',{});$('join').onclick=()=>send('tt_join',{p_code:$('code').value.trim().toUpperCase(),p_name:$('name').value.trim()});$('start').onclick=()=>{if(confirm('Start with the current players? Joining will close.'))command('start',{p_size:Number($('boardSize').value)});};
document.querySelectorAll('[data-action]').forEach(b=>b.onclick=()=>command(b.dataset.action,{p_target:Number($('target').value)}));document.querySelectorAll('[data-move]').forEach(b=>b.onclick=()=>command('move',{p_direction:b.dataset.move}));
$('remove').onclick=()=>{if(confirm('Withdraw permanently? You will still be able to vote.'))command('remove');};$('close').onclick=()=>command('close');$('next').onclick=()=>{if(confirm('Advance one day, award points and expire shields?'))command('next_day');};$('vote').onclick=()=>command('vote',{p_target:Number($('voteTarget').value)});$('retry').onclick=()=>{if(pending)send(pending.name,pending.args);};
if(!SUPABASE_URL||!SUPABASE_PUBLISHABLE_KEY){setText('connectionStatus','Online play needs a Supabase project. Follow ONLINE_SETUP.md, then fill in online-config.js.');$('connect').disabled=true;}else setText('connectionStatus','Ready. Connect to create or join a room.');
