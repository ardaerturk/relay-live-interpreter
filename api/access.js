import { authenticate, fail, redeem } from '../lib/access.mjs';
import { deviceCookie, readBody, route, setDevice } from '../lib/http.mjs';
export default route(async(req,res)=>{
  if(req.method==='GET') return { unlocked:Boolean(await authenticate(deviceCookie(req))) };
  if(req.method!=='POST') fail(405,'Method not allowed.');
  const {invite}=await readBody(req,1024);
  setDevice(res,await redeem(invite)); return {unlocked:true};
});
