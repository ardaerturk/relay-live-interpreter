import {createServer} from 'node:http';
import {createServer as viteServer} from 'vite';
import access from '../api/access.js';
import connect from '../api/connect.js';
import history from '../api/history.js';
const port=Number(process.env.PORT||4173);
process.env.APP_ORIGIN ??= 'http://localhost:'+port;
const routes=new Map([['/api/access',access],['/api/connect',connect],['/api/history',history]]);
const http=createServer(async(req,res)=>{
  const path=new URL(req.url,'http://localhost').pathname, handler=routes.get(path);
  if(handler) return handler(req,res);
  if(path.startsWith('/api/')){res.writeHead(404).end();return;}
  vite.middlewares(req,res);
});
const vite=await viteServer({server:{middlewareMode:true,hmr:{server:http},fs:{deny:['.env','.env.*','**/*.{crt,pem}','**/.git/**','**/lib/**','**/api/**','**/scripts/**','**/tests/**']}}});
http.listen(port,'localhost',()=>console.log('Relay: http://localhost:'+port));
