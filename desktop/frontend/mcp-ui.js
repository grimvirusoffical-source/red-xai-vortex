'use strict';
(() => {
  const root=document.querySelector('#tab-mcp');if(!root)return;
  const get=id=>document.getElementById('mcp-'+id);
  let definitions=[];let selected='';
  function message(text){get('message').textContent=text;}
  function form(d={}){
    selected=d.id||'';
    for(const [id,key]of [['name','name'],['url','url'],['command','command'],['cwd','workingDirectory'],['keyname','keyName'],['connect-timeout','connectTimeout'],['call-timeout','callTimeout']])get(id).value=d[key]||'';
    get('type').value=d.type||'http';get('auth').value=d.authMode||'none';get('protocol').value=d.protocolVersion||'2025-11-25';
    get('args').value=(d.args||[]).join('\n');get('key').value='';get('username').value='';get('headers').value='';get('environment').value='';get('clear').checked=false;
    get('key').placeholder=d.hasKey?'Blank keeps the saved key':'Optional provider API key';
    get('enabled').checked=d.enabled!==false;get('auto').checked=d.autoConnect!==false;get('inherit').checked=!!d.inheritEnvironment;
    transport();message('');
  }
  function transport(){const local=get('type').value==='stdio';get('local').hidden=!local;get('remote').hidden=local;}
  async function refresh(){
    const r=await bridge.call('mcp.list');if(!r.ok){message(r.error||'Sign in to manage MCP servers.');return}
    definitions=r.servers||[];get('list').replaceChildren();
    for(const d of definitions){
      const row=document.createElement('div');row.className='row card';
      const label=document.createElement('strong');label.textContent=d.name+' · '+d.type;row.append(label);
      for(const [text,action]of [['Edit',()=>form(d)],['Test',()=>test(d.id)],['Connect',()=>connect(d.id)],['Disconnect',()=>act('mcp.disconnect',d.id)],['Delete',()=>{if(confirm('Delete this account’s '+d.name+' connection?'))act('mcp.delete',d.id)}]]){
        const b=document.createElement('button');b.type='button';b.textContent=text;b.onclick=action;row.append(b);
      }
      get('list').append(row);
    }
  }
  async function act(method,id){try{const r=await bridge.call(method,{id});message(r.message||r.error||(r.ok?'Done':'Request failed'));if(r.ok)await refresh();}catch(e){message(String(e.message))}}
  async function test(id){message('Testing initialization and tool discovery…');await act('mcp.test',id)}
  async function connect(id){message('Connecting…');await act('mcp.connect',id)}
  function timeout(id){const text=get(id).value.trim();if(!text)return 0;const n=Number(text);if(!Number.isInteger(n)||n<1||n>3600)throw Error('Timeouts must be 1–3600 seconds or blank');return n}
  function dict(id){const text=get(id).value.trim();if(!text)return undefined;const value=JSON.parse(text);if(!value||Array.isArray(value)||typeof value!=='object'||Object.values(value).some(x=>typeof x!=='string'))throw Error('Headers and environment need JSON objects with string values');return value}
  get('save').onclick=async()=>{
    try{
      const old=definitions.find(d=>d.id===selected)||{};
      const server={...old,id:selected||('server-'+crypto.randomUUID().slice(0,18)),name:get('name').value.trim(),type:get('type').value,url:get('url').value.trim(),command:get('command').value.trim(),args:get('args').value.split('\n').filter(x=>x.length),workingDirectory:get('cwd').value.trim(),authMode:get('auth').value,keyName:get('keyname').value.trim(),connectTimeout:timeout('connect-timeout'),callTimeout:timeout('call-timeout'),protocolVersion:get('protocol').value,enabled:get('enabled').checked,autoConnect:get('auto').checked,inheritEnvironment:get('inherit').checked};
      const input={server,apiKey:get('key').value,username:get('username').value,clearKey:get('clear').checked};
      for(const name of ['headers','environment']){const value=dict(name);if(value!==undefined)input[name]=value}
      const r=await bridge.call('mcp.save',input);if(!r.ok)throw Error(r.error||'Unable to save');
      get('key').value='';get('username').value='';get('headers').value='';get('environment').value='';get('clear').checked=false;selected=server.id;
      await refresh();message('Saved for this account. Use Test to verify the connection.');
    }catch(e){message(e.message)}
  };
  get('new').onclick=()=>form();get('refresh').onclick=refresh;get('type').onchange=transport;
  get('firecrawl').onclick=()=>form({name:'Firecrawl',type:'http',url:'https://mcp.firecrawl.dev/v2/mcp',authMode:'bearer'});
  get('firecrawl-local').onclick=()=>form({name:'Firecrawl',type:'stdio',command:'npx',args:['-y','firecrawl-mcp'],authMode:'environment',keyName:'FIRECRAWL_API_KEY'});
  document.querySelector('[data-tab="mcp"]').addEventListener('click',refresh);
  window.addEventListener('vortex-account-changed',()=>{definitions=[];selected='';get('list').replaceChildren();form();});
  form();
})();
