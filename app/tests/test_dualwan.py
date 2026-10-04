"""Offline DHCP event tests. All networking commands are replaced with mocks."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import json
import sys

SOURCE = Path(__file__).resolve().parents[1] / 'dualwan/dhcp-event.sh'


class DHCPIsolationTests(unittest.TestCase):
    def run_event(self, event='bound', **changes):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            commands = root / 'commands'
            commands.mkdir()
            log = root / 'calls'
            ip = commands / 'ip'
            ip.write_text('#!/bin/sh\nprintf "ip %s\\n" "$*" >> "$TEST_LOG"\n'
                          'if [ "$*" = "-4 addr show dev eth0" ]; then echo "    inet 10.64.32.47/17 scope global eth0"; fi\n')
            ip.chmod(0o700)
            logger = commands / 'logger'
            logger.write_text('#!/bin/sh\nexit 0\n'); logger.chmod(0o700)
            controller = root / 'dualwan.sh'
            controller.write_text('#!/bin/sh\nprintf "controller %s\\n" "$*" >> "$TEST_LOG"\n')
            controller.chmod(0o700)
            event_script = root / 'event.sh'
            event_script.write_text(SOURCE.read_text().replace('BASE=/data/mentoglass-dualwan', f'BASE={root}'))
            env = dict(os.environ, PATH=str(commands) + ':' + os.environ['PATH'], TEST_LOG=str(log),
                       interface='eth1.3', ip='10.64.32.50', subnet='255.255.128.0',
                       router='10.64.127.254', lease='3600')
            env.update(changes)
            (root / 'balancing').touch()
            p = subprocess.run(['/bin/sh', str(event_script), event], env=env, capture_output=True, text=True)
            return p.returncode, log.read_text() if log.exists() else '', (root / 'lease').read_text() if (root / 'lease').exists() else '', (root / 'balancing').exists()

    def test_overlapping_subnet_keeps_primary_routes(self):
        code, calls, lease, _ = self.run_event()
        self.assertEqual(code, 0)
        self.assertIn('route del 10.64.0.0/17 dev eth1.3 table main', calls)
        self.assertIn('route replace default via 10.64.127.254 dev eth1.3 src 10.64.32.50 table 202', calls)
        self.assertIn('from 10.64.32.50/32 table 202', calls)
        self.assertNotIn('dev eth0 table main', calls)
        self.assertNotIn('route flush', calls)
        self.assertIn('ip=10.64.32.50', lease)

    def test_wrong_interface_refused(self):
        code, calls, _, _ = self.run_event(interface='br-lan')
        self.assertNotEqual(code, 0)
        self.assertEqual(calls, '')

    def test_duplicate_first_wan_address_refused(self):
        code, calls, lease, _ = self.run_event(ip='10.64.32.47')
        self.assertNotEqual(code, 0)
        self.assertNotIn('addr replace', calls)
        self.assertEqual(lease, '')

    def test_malformed_and_discontiguous_mask_refused(self):
        for changes in [dict(ip='10.64.32.999'), dict(subnet='255.128.255.0'), dict(router='10.64.127.254;id')]:
            with self.subTest(changes=changes):
                code, calls, _, _ = self.run_event(**changes)
                self.assertNotEqual(code, 0)
                self.assertNotIn('addr replace', calls)

    def test_lease_loss_pauses_without_deleting_preference(self):
        code, calls, _, enabled = self.run_event(event='deconfig')
        self.assertEqual(code, 0)
        self.assertIn('controller pause', calls)
        self.assertNotIn('controller balance-off', calls)
        self.assertTrue(enabled)


class AccelerationTests(unittest.TestCase):
    def test_unverified_or_disabled_router_stays_in_software(self):
        for verified, enabled, expected in [(False, False, '1'), (False, True, '1'), (True, False, '1'), (True, True, '2')]:
            with self.subTest(verified=verified, enabled=enabled), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                mode = root / 'accel_mode'; mode.write_text('2\n')
                if verified: (root / 'hardware-acceleration-verified').touch()
                if enabled: (root / 'hardware-acceleration-enabled').touch()
                source = (SOURCE.parent / 'dualwan.sh').read_text().split('case "${1:-status}" in')[0]
                source = source.replace('BASE=/data/mentoglass-dualwan', f'BASE={root}').replace('/sys/kernel/debug/ecm/ecm_classifier_default/accel_mode', str(mode))
                script = root / 'policy.sh'; script.write_text(source + '\napply_acceleration\n')
                subprocess.run(['/bin/sh', str(script)], check=True, capture_output=True)
                self.assertEqual(mode.read_text().strip(), expected)
                self.assertEqual((root / 'ecm-original').read_text().strip(), '2')

    def test_disabling_acceleration_removes_cache_and_keeps_balancing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            mode = root / 'accel_mode'; mode.write_text('2\n')
            cache = root / 'defunct_all'; cache.write_text('0\n')
            for name in ['hardware-acceleration-verified', 'hardware-acceleration-enabled', 'balancing']:
                (root / name).touch()
            source = (SOURCE.parent / 'dualwan.sh').read_text().replace('BASE=/data/mentoglass-dualwan', f'BASE={root}').replace('/sys/kernel/debug/ecm/ecm_classifier_default/accel_mode', str(mode)).replace('/sys/kernel/debug/ecm/ecm_db/defunct_all', str(cache))
            script = root / 'controller.sh'; script.write_text(source)
            subprocess.run(['/bin/sh', str(script), 'hardware-off'], check=True, capture_output=True)
            self.assertFalse((root / 'hardware-acceleration-enabled').exists())
            self.assertTrue((root / 'balancing').exists())
            self.assertEqual(mode.read_text().strip(), '1')
            self.assertEqual(cache.read_text().strip(), '1')


class SelectorTests(unittest.TestCase):
    def test_primary_process_loss_selects_only_second_without_gap(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); commands = root / 'commands'; commands.mkdir()
            db = root / 'iptables.json'; db.write_text(json.dumps({'MG_BALANCE': [], 'MG_SELECT': []}))
            mock = commands / 'iptables'
            mock.write_text(f'#!{sys.executable}\n' + '''import os,sys,json
p=os.environ['TEST_DB']; d=json.load(open(p)); a=sys.argv[1:]
if a[0]=='-w': a=a[1:]
if a[0]=='-t': a=a[2:]
op,chain,*rule=a
if op=='-nL': sys.exit(0 if chain in d else 1)
if op=='-N': d[chain]=[]
elif op=='-C': sys.exit(0 if rule in d.get(chain,[]) else 1)
elif op=='-A': d[chain].append(rule)
elif op=='-I': d[chain].insert(0,rule)
elif op=='-D': d[chain].remove(rule)
else: sys.exit(2)
json.dump(d,open(p,'w'))
with open(os.environ['TEST_CALLS'],'a') as f:f.write(' '.join(a)+'\\n')
''')
            mock.chmod(0o700)
            for name, body in {
                'pidof': 'test "$PRIMARY_UP" = yes',
                'cat': 'echo 1',
                'ubus': 'echo \'{"up":true}\'',
                'jsonfilter': 'echo true',
                'swconfig': 'test "$*" = "dev switch1 port 4 get link" || exit 2; echo "port:4 link:${PRIMARY_LINK:-up}"',
            }.items():
                path = commands / name; path.write_text('#!/bin/sh\n' + body + '\n'); path.chmod(0o700)
            source = (SOURCE.parent / 'dualwan.sh').read_text().split('case "${1:-status}" in')[0]
            script = root / 'selector.sh'
            script.write_text(source.replace('BASE=/data/mentoglass-dualwan', f'BASE={root}') + '\nset_balance on\n')
            calls = root / 'calls'
            env = dict(os.environ, PATH=str(commands)+':'+os.environ['PATH'], TEST_DB=str(db), TEST_CALLS=str(calls), PRIMARY_UP='yes')
            subprocess.run(['/bin/sh',str(script)],env=env,check=True,capture_output=True)
            self.assertEqual(json.loads(db.read_text())['MG_BALANCE'], [['-j','MG_SELECT']])
            env['PRIMARY_UP']='no'
            subprocess.run(['/bin/sh',str(script)],env=env,check=True,capture_output=True)
            self.assertEqual(json.loads(db.read_text())['MG_BALANCE'], [['-j','MG_ONLY2']])
            log=calls.read_text()
            self.assertLess(log.index('-I MG_BALANCE -j MG_ONLY2'),log.index('-D MG_BALANCE -j MG_SELECT'))
            # The CPU link and authentication process remain up when the cable
            # fails. Only the physical switch port reveals this failure.
            env['PRIMARY_UP']='yes'
            for link in ['down', 'unknown']:
                env['PRIMARY_LINK']=link
                subprocess.run(['/bin/sh',str(script)],env=env,check=True,capture_output=True)
                self.assertEqual(json.loads(db.read_text())['MG_BALANCE'], [['-j','MG_ONLY2']])
            env['PRIMARY_LINK']='up'
            subprocess.run(['/bin/sh',str(script)],env=env,check=True,capture_output=True)
            self.assertEqual(json.loads(db.read_text())['MG_BALANCE'], [['-j','MG_SELECT']])


class RouteAndARPTests(unittest.TestCase):
    def test_arp_isolation_changes_only_campus_interfaces(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for dev in ['eth0','eth1.3','br-lan']:
                (root/dev).mkdir()
                for key in ['arp_ignore','arp_announce']:
                    (root/dev/key).write_text('0\n')
            source=(SOURCE.parent/'dualwan.sh').read_text().split('case "${1:-status}" in')[0]
            source=source.replace('/proc/sys/net/ipv4/conf/', str(root)+'/')
            script=root/'isolate.sh'; script.write_text(source+'\nisolate_arp\nisolate_arp\n')
            subprocess.run(['/bin/sh',str(script)],check=True,capture_output=True)
            for dev in ['eth0','eth1.3']:
                self.assertEqual((root/dev/'arp_ignore').read_text().strip(),'1')
                self.assertEqual((root/dev/'arp_announce').read_text().strip(),'2')
            self.assertEqual((root/'br-lan/arp_ignore').read_text().strip(),'0')
            self.assertEqual((root/'br-lan/arp_announce').read_text().strip(),'0')

    def run_routes(self, race=False, fail=False):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); commands=root/'commands'; commands.mkdir()
            db=root/'routes.json'; calls=root/'calls'
            main=['default via 10.65.127.254 proto static src 10.65.32.47',
                  '10.65.0.0/17 proto kernel scope link src 10.65.32.47']
            old=[['default via 10.64.127.254 metric 50','eth0'],
                 ['default via 10.64.127.254 proto static src 10.64.32.47','eth0'],
                 ['10.64.0.0/17 proto kernel scope link src 10.64.32.47','eth0'],
                 ['192.168.31.0/24 scope link','br-lan']]
            original={'main':main,'201':old,'202':[['default via 10.64.127.254','eth1.3']], 'shows':0}
            db.write_text(json.dumps(original))
            mock=commands/'ip'
            mock.write_text(f'#!{sys.executable}\n'+'''import json,os,sys
p=os.environ['TEST_DB']; d=json.load(open(p)); a=sys.argv[1:]
with open(os.environ['TEST_CALLS'],'a') as f:f.write(' '.join(a)+'\\n')
if a==['-4','rule','show']:
 print('1101: from all fwmark 0x100/0x300 lookup 201\\n1102: from all fwmark 0x200/0x300 lookup 202');sys.exit(0)
if a[:4]==['-4','route','show','table']:
 table=a[4]
 if table=='main':
  d['shows']+=1
  if os.environ.get('TEST_RACE')=='yes' and d['shows']==2:d['main'].append('10.66.0.0/17 proto kernel scope link src 10.66.32.47')
  print('\\n'.join(d['main']))
 else:print('\\n'.join(line for line,dev in d[table] if dev=='eth0'))
 json.dump(d,open(p,'w'));sys.exit(0)
if a[:2]!=['-4','route']:sys.exit(2)
op=a[2]; words=a[3:]
idx=words.index('table'); table=words[idx+1];del words[idx:idx+2]
idx=words.index('dev'); dev=words[idx+1];del words[idx:idx+2]
line=' '.join(words)
def key(row):
 t=row[0].split();return t[0], t[t.index('metric')+1] if 'metric' in t else '0'
row=[line,dev]
if os.environ.get('TEST_FAIL')=='yes' and op=='replace' and words[0]=='10.65.0.0/17':sys.exit(1)
if op=='replace':d[table]=[r for r in d[table] if key(r)!=key(row)]+[row]
elif op=='del':d[table]=[r for r in d[table] if not (key(r)==key(row) and r[1]==dev)]
else:sys.exit(2)
json.dump(d,open(p,'w'))
'''); mock.chmod(0o700)
            flock=commands/'flock'; flock.write_text('#!/bin/sh\nexit 0\n');flock.chmod(0o700)
            source=(SOURCE.parent/'dualwan.sh').read_text().split('case "${1:-status}" in')[0]
            script=root/'route.sh';script.write_text(source.replace('BASE=/data/mentoglass-dualwan',f'BASE={root}')+'\nroute_first\n')
            env=dict(os.environ,PATH=str(commands)+':'+os.environ['PATH'],TEST_DB=str(db),TEST_CALLS=str(calls),
                     TEST_RACE='yes' if race else 'no', TEST_FAIL='yes' if fail else 'no')
            p=subprocess.run(['/bin/sh',str(script)],env=env,capture_output=True,text=True)
            return p.returncode,json.loads(db.read_text()),calls.read_text(),original,list(root.glob('.route-first.*'))

    def test_renewal_installs_new_routes_before_removing_stale_routes(self):
        code, state, calls, original, temps=self.run_routes()
        self.assertEqual(code,0)
        self.assertEqual(state['main'],original['main'])
        self.assertEqual(state['202'],original['202'])
        self.assertEqual([line for line,dev in state['201'] if dev=='eth0'],original['main'])
        self.assertTrue(any(dev=='br-lan' for _,dev in state['201']))
        self.assertLess(calls.index('route replace table 201 10.65.'),calls.index('route del table 201'))
        self.assertEqual(temps,[])

    def test_concurrent_dhcp_change_postpones_route_deletion(self):
        code,state,calls,original,temps=self.run_routes(race=True)
        self.assertEqual(code,0)
        self.assertNotIn('route del',calls)
        self.assertEqual(state['202'],original['202'])
        self.assertEqual(temps,[])

    def test_failed_route_install_never_deletes_existing_routes(self):
        code,state,calls,original,temps=self.run_routes(fail=True)
        self.assertNotEqual(code,0)
        self.assertNotIn('route del',calls)
        self.assertEqual(state['main'],original['main'])
        self.assertEqual(state['202'],original['202'])
        self.assertEqual(temps,[])


if __name__ == '__main__':
    unittest.main()
