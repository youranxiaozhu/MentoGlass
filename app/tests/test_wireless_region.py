"""Offline region transactions, asynchronous application and recovery; no real radio actions."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'mentoglass_wireless_region.sh'


class RegionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); self.base = self.root / 'data'; self.base.mkdir()
        self.cfg = self.root / 'config'; self.cfg.mkdir()
        self.config = self.cfg / 'wireless'
        self.original = {'wifi0.type': 'qcawificfg80211', 'wifi1.type': 'qcawificfg80211',
                         'wifi0.country': 'CN', 'wifi1.country': 'CN', 'wifi1.bw': '160',
                         'wifi1.channel': '44', 'wifi0.ssid': 'keep-name', 'wifi0.key': 'test-only',
                         'wifi1.dfs': '1', 'unknown': 'keep'}
        self.config.write_text(json.dumps(self.original))
        self.runtime = self.root / 'runtime'; self.runtime.write_text(json.dumps({'wl0': 156, 'wl1': 156}))
        self.boot = self.root / 'boot'; self.boot.write_text('test-boot')
        self.commands = self.root / 'commands'; self.commands.mkdir()
        self.calls = self.root / 'calls'
        self.env = dict(os.environ, PATH=str(self.commands)+':'+os.environ['PATH'],
                        TEST_CONFIG=str(self.config), TEST_RUNTIME=str(self.runtime), TEST_CALLS=str(self.calls))
        self.mock('uci', '''import sys,os,json
a=sys.argv[1:]; root=os.path.dirname(os.environ['TEST_CONFIG']); quiet=False
while a and a[0].startswith('-'):
    flag=a.pop(0)
    if flag=='-c':root=a.pop(0)
    elif flag=='-P':a.pop(0)
    elif flag=='-q':quiet=True
    else:sys.exit(9)
p=os.path.join(root,'wireless'); cmd=a.pop(0)
d=json.load(open(p))
if cmd=='changes':
    if os.environ.get('TEST_UNSAVED')=='yes':print('wireless.wifi1.channel=48')
elif cmd=='get':
    k=a[0].removeprefix('wireless.')
    if k not in d:sys.exit(1)
    print(d[k])
elif cmd=='set':
    k,v=a[0].split('=',1);d[k.removeprefix('wireless.')]=v
    json.dump(d,open(p,'w'))
elif cmd=='commit':pass
else:sys.exit(9)
''')
        self.mock('iwpriv', '''import sys,os,json
if os.environ.get('TEST_RUNTIME_MISSING')=='yes':sys.exit(1)
v=json.load(open(os.environ['TEST_RUNTIME']))[sys.argv[1]]
print(sys.argv[1]+' get_countrycode:'+str(v))
''')
        self.mock('md5sum', '''import sys,hashlib
print(hashlib.md5(open(sys.argv[1],'rb').read()).hexdigest()+'  '+sys.argv[1])
''')
        self.mock('flock', '''import os,sys
sys.exit(1 if os.environ.get('TEST_LOCK_BUSY')=='yes' else 0)
''')
        self.mock('wifi', '''import os,sys,json
calls=os.environ['TEST_CALLS'];n=len(open(calls).readlines()) if os.path.exists(calls) else 0
with open(calls,'a') as f:f.write(' '.join(sys.argv[1:])+'\\n')
p=os.environ['TEST_CONFIG'];d=json.load(open(p))
if n==0 and os.environ.get('TEST_EXTERNAL_EDIT')=='yes':
    d['wifi0.ssid']='external-edit';json.dump(d,open(p,'w'));sys.exit(1)
if (n==0 and os.environ.get('TEST_APPLY_FAIL')=='yes') or os.environ.get('TEST_RESTORE_FAIL')=='yes':sys.exit(1)
if os.environ.get('TEST_WRONG_RUNTIME')!='yes':
    ids={'CN':156,'US':840,'JP':392}
    json.dump({'wl0':ids[d['wifi1.country']],'wl1':ids[d['wifi0.country']]},open(os.environ['TEST_RUNTIME'],'w'))
''')
        self.script = self.base / 'region.sh'
        source = SOURCE.read_text().replace('BASE=/data/mentoglass-wireless', 'BASE='+str(self.base)).replace('CONFIG=/etc/config/wireless', 'CONFIG='+str(self.config)).replace('SCRIPT=/data/mentoglass-wireless/region.sh', 'SCRIPT='+str(self.script)).replace('/proc/sys/kernel/random/boot_id',str(self.boot)).replace('/sbin/wifi',str(self.commands/'wifi'))
        self.script.write_text(source)

    def mock(self, name, code):
        p=self.commands/name; p.write_text('#!'+sys.executable+'\n'+code); p.chmod(0o700)

    def run_action(self,*args):
        return subprocess.run(['/bin/sh',str(self.script),*args],env=self.env,capture_output=True,text=True,timeout=10)

    def prepare_worker(self):
        self.assertEqual(self.run_action('save','US').returncode,0)
        (self.base/'job-state').write_text('queued\n')

    def test_save_changes_only_both_country_fields_and_does_not_reload(self):
        original=self.config.read_bytes()
        self.assertEqual(self.run_action('save','US').returncode,0)
        expected=dict(self.original,**{'wifi0.country':'US','wifi1.country':'US'})
        self.assertEqual(json.loads(self.config.read_text()),expected)
        self.assertEqual((self.base/'wireless-before-region.conf').read_bytes(),original)
        self.assertFalse(self.calls.exists())
        self.assertEqual((self.base/'wireless-before-region.conf').stat().st_mode & 0o777,0o600)
        self.assertIn('WifiRegionPending=yes',self.run_action('status').stdout)
        self.assertEqual(self.run_action('save','JP').returncode,0)
        self.assertEqual((self.base/'wireless-before-region.conf').read_bytes(),original)

    def test_invalid_region_unsaved_and_concurrent_changes_do_not_write(self):
        original=self.config.read_bytes()
        for code in ['00','US;id','ZZ','us','US\n']:
            self.assertNotEqual(self.run_action('save',code).returncode,0)
            self.assertEqual(self.config.read_bytes(),original)
        self.env['TEST_UNSAVED']='yes'
        self.assertNotEqual(self.run_action('save','US').returncode,0)
        self.assertEqual(self.config.read_bytes(),original)
        del self.env['TEST_UNSAVED']
        self.assertEqual(self.run_action('save','US').returncode,0)
        d=json.loads(self.config.read_text());d['wifi0.ssid']='external-edit';self.config.write_text(json.dumps(d))
        self.assertNotEqual(self.run_action('apply').returncode,0)
        self.assertNotEqual(self.run_action('save','JP').returncode,0)
        self.assertEqual(json.loads(self.config.read_text())['wifi0.ssid'],'external-edit')

    def test_queue_returns_before_wifi_reload_and_worker_verifies_both_radios(self):
        self.assertEqual(self.run_action('save','US').returncode,0)
        t=time.monotonic();result=self.run_action('apply')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertLess(time.monotonic()-t,2)
        self.assertFalse(self.calls.exists())
        deadline=time.monotonic()+8
        while time.monotonic()<deadline:
            if (self.base/'job-state').read_text().strip()=='applied':break
            time.sleep(.1)
        self.assertEqual((self.base/'job-state').read_text().strip(),'applied')
        self.assertEqual(self.calls.read_text(),'reload_legacy\n')
        self.assertEqual(json.loads(self.runtime.read_text()),{'wl0':840,'wl1':840})
        self.assertFalse((self.base/'pending').exists())

    def test_failed_apply_restores_config_without_touching_authentication(self):
        original=self.config.read_bytes();self.prepare_worker();self.env['TEST_APPLY_FAIL']='yes'
        self.assertEqual(self.run_action('worker').returncode,0)
        self.assertEqual(self.config.read_bytes(),original)
        self.assertEqual((self.base/'job-state').read_text().strip(),'rolled-back')
        self.assertEqual(self.calls.read_text(),'reload_legacy\nreload_legacy\n')

    def test_external_change_during_apply_is_preserved(self):
        self.prepare_worker();self.env['TEST_EXTERNAL_EDIT']='yes'
        self.assertEqual(self.run_action('worker').returncode,0)
        self.assertEqual((self.base/'job-state').read_text().strip(),'failed-config-changed')
        self.assertEqual(json.loads(self.config.read_text())['wifi0.ssid'],'external-edit')
        self.assertEqual(self.calls.read_text(),'reload_legacy\n')

    def test_missing_driver_read_is_unknown_and_interrupted_job_does_not_block_save(self):
        self.env['TEST_RUNTIME_MISSING']='yes'
        self.assertIn('WifiRuntimeCountry0ID=unknown\n',self.run_action('status').stdout)
        (self.base/'job-state').write_text('applying\n');(self.base/'job-pid').write_text(str(os.getpid()))
        (self.base/'job-boot').write_text('old-boot')
        self.assertIn('WifiRegionJob=interrupted',self.run_action('status').stdout)
        self.assertEqual(self.run_action('save','US').returncode,0)


if __name__=='__main__':unittest.main()
