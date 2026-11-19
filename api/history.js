import {authenticate,fail} from '../lib/access.mjs';
import {deviceCookie,readBody,route} from '../lib/http.mjs';
import {list,read,remove,save} from '../lib/history.mjs';
export default route(async req=>{
  const device=await authenticate(deviceCookie(req));
  if(!device)fail(401,'Unlock this device to use history.');
  const params=new URL(req.url,'http://localhost').searchParams,id=params.get('id');
  if(req.method==='GET')return id===null?list(device,params.get('after')):read(device,id);
  if(req.method==='DELETE')return remove(device,id);
  if(req.method==='POST')return save(device,await readBody(req,1100000));
  fail(405,'Method not allowed.');
});
