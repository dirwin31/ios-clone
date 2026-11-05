// Node.js 20+. Supply IOS_RELEASE_KEY from a local secret store or CI secret.
// No credential is accepted on the command line or printed in errors.
const usage = 'node notify-ios.mjs --user DISCORD_ID --report UUID --version VERSION --build NUMBER --message "Relevant change" [--send --available]';
const args = process.argv.slice(2), options = {};
try {
  const values = new Set(['user','report','version','build','message']);
  for (let i = 0; i < args.length; i++) {
    const key = args[i].replace(/^--/, '');
    if (!args[i].startsWith('--') || Object.hasOwn(options,key)) throw Error(usage);
    if (['send','available'].includes(key)) options[key] = true;
    else if (values.has(key) && args[i+1] && !args[i+1].startsWith('--')) options[key] = args[++i];
    else throw Error(usage);
  }
  if ([...values].some(key => !options[key])) throw Error(usage);
  if (options.send && !options.available) throw Error('Use --available only after checking the reporter can access this build in TestFlight.');
  const key = process.env.IOS_RELEASE_KEY;
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
