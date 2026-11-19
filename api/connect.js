import { authenticate, fail, reserveStart } from '../lib/access.mjs';
import { deviceCookie, readBody, route } from '../lib/http.mjs';
import { negotiate, validateOffer } from '../lib/translator.mjs';
export default route(async req=>{
  if(req.method!=='POST') fail(405,'Method not allowed.');
  const device=await authenticate(deviceCookie(req)); if(!device) fail(401,'A device invite is required.');
  const offer=await readBody(req,65536); validateOffer(offer);
  await reserveStart(device);
  return negotiate(offer);
});
