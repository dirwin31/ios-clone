import {readFile} from 'node:fs/promises';
import {createInterface} from 'node:readline/promises';
import {defaultRegistry,defaultKeyFile,setupKey,loadKey,resolveReport,loadRegistry} from './notify-support.mjs';
// Node.js 20+. Supply IOS_RELEASE_KEY from a local secret store or CI secret.
// No credential is accepted on the command line or printed in errors.
const usage = 'node notify-ios.mjs --user DISCORD_ID --report UUID --version VERSION --build NUMBER --message "Relevant change" [--send --available]';
const args = process.argv.slice(2), options = {};
try {
  const values = new Set(['user','report','report-file','registry','key-file','version','build','message']);
  for (let i = 0; i < args.length; i++) {
    const key = args[i].replace(/^--/, '');
    if (!args[i].startsWith('--') || Object.hasOwn(options,key)) throw Error(usage);
    if (['send','available','setup'].includes(key)) options[key] = true;
    else if (values.has(key) && args[i+1] && !args[i+1].startsWith('--')) options[key] = args[++i];
    else throw Error(usage);
  }
  const keyFile=options['key-file'] || defaultKeyFile;
  if(options.setup) {await setupKey(keyFile);console.log('Key saved to '+keyFile+'\nSet that key once as the Cloudflare IOS_RELEASE_KEY secret. Future runs load it automatically.');process.exit(0);}
  if(!args.length) {
    const prompt=createInterface({input:process.stdin,output:process.stdout});
    try {
      options.report=await prompt.question('Report reference (looked up automatically): ');
      options.version=await prompt.question('App version: ');
      options.build=await prompt.question('TestFlight build number: ');
      options.message=await prompt.question('Short update for this report: ');
      console.log('Update: '+options.message+' | Version '+options.version+' | Build '+options.build);
      options.send=(await prompt.question('Is it available to this tester, and should this notice be sent? Type SEND, or Enter to check only: '))==='SEND';
      options.available=options.send;
    }finally{prompt.close();}
  }
  for(const field of ['version','build','message']) if(!options[field]) throw Error(usage);
  const reportText=options['report-file'] ? await readFile(options['report-file'],'utf8') : options.report || '';
  const identity=resolveReport(reportText,options.user,await loadRegistry(options.registry || defaultRegistry));
  options.user=identity.userID;options.report=identity.reference;
  if (options.send && !options.available) throw Error('Use --available only after checking the reporter can access this build in TestFlight.');
  const key = await loadKey(keyFile);
  if (!key || !/^[A-Za-z0-9_-]{43,128}$/.test(key)) throw Error('Set IOS_RELEASE_KEY through your local secret store or CI secrets first.');
  const body = {userID:options.user,reference:options.report,version:options.version,build:options.build,message:options.message,available:!!options.available};
  console.log(options.send ? 'Sending iOS notice for this report.' : 'Checking report and existing delivery status; no message will be sent.');
  const response = await fetch('https://starpilot-log-relay.nathan-g-hubbard.workers.dev/v1/ios/build-notice' + (options.send ? '' : '/status'), {
    method:'POST', headers:{'Content-Type':'application/json',Authorization:'Bearer '+key},body:JSON.stringify(body),redirect:'error',signal:AbortSignal.timeout(45000)
  });
  const result = await response.json();
  if (!response.ok) throw Error('Request failed (HTTP '+response.status+'): '+(result.state || result.error || 'Unknown response'));
  console.log('Status: '+result.state);
  if (result.state === 'unconfirmed') throw Error('Delivery is uncertain. Do not change the build number to resend; contact the maintainer.');
  if (result.state === 'rate_limited') throw Error('Discord rate limited the request. Wait before rerunning the identical command.');
  if (options.send && result.state !== 'sent') throw Error('Notice was not confirmed sent. Contact the maintainer before retrying.');
} catch (error) {
  console.error(error instanceof TypeError || error.name === 'TimeoutError' ? 'Network request failed. Check status with the same arguments before trying to send again.' : error.message);
  process.exitCode = 1;
}
