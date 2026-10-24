#!/usr/bin/env python3
"""Run the real Squirrel librime/librime-lua in an isolated copied work directory.
No UI automation, system input changes, or real userdb access. Requires Xcode CLT.
"""
from pathlib import Path
import argparse, hashlib, json, os, re, shutil, subprocess, tempfile, time
from datetime import datetime, timezone

p=argparse.ArgumentParser()
p.add_argument('--project', type=Path, default=Path(__file__).resolve().parents[2])
p.add_argument('--source-user', type=Path, default=Path.home()/'Library/Rime')
p.add_argument('--bundle', type=Path, default=Path.home()/'Library/Input Methods/Squirrel.app')
p.add_argument('--work-root', type=Path, default=Path.cwd()/'work')
p.add_argument('--results', type=Path)
a=p.parse_args()
project=a.project.resolve(); src=a.source_user.resolve(); bundle=a.bundle.resolve()
work=a.work_root.resolve();work.mkdir(parents=True,exist_ok=True)
if work.name!='work': raise SystemExit('--work-root must be a dedicated directory named work')
run_dir=Path(tempfile.mkdtemp(prefix='rime-gloss-integration-',dir=work))
user=run_dir/'user';user.mkdir()
native=project/'tests/native'
framework=bundle/'Contents/Frameworks';shared=bundle/'Contents/SharedSupport'
for name in ('build','lua','opencc','cn_dicts','en_dicts'):
    if (src/name).is_dir():shutil.copytree(src/name,user/name)
for pattern in ('*.yaml','*.txt'):
    for file in src.glob(pattern):shutil.copy2(file,user/file.name)
# Source dictionaries and compiled dictionaries only; never copy *.userdb.
shutil.copy2(project/'lua/en_gloss.lua',user/'lua/en_gloss.lua')
shutil.copy2(project/'schema-patch.yaml',user/'double_pinyin_sogou.custom.yaml')
shutil.copytree(project/'en_gloss',user/'en_gloss',dirs_exist_ok=True)
probe=run_dir/'probe'
subprocess.run(['clang','-std=c11','-D_DARWIN_C_SOURCE','-Wall','-Wextra',f'-Wl,-rpath,{framework}',str(native/'probe.c'),'-o',str(probe)],check=True)
deploy=subprocess.run([str(bundle/'Contents/MacOS/rime_deployer'),'--build',str(user),str(shared),str(user/'build')],text=True,capture_output=True,check=True)
(run_dir/'deploy.log').write_text(deploy.stdout+deploy.stderr)
env=dict(os.environ,RIME_PROBE_FRAMEWORKS=str(framework))
results={'tested_at_utc':datetime.now(timezone.utc).isoformat(),'module_sha256':hashlib.sha256((project/'lua/en_gloss.lua').read_bytes()).hexdigest(),'isolated_directory':'<temporary>/user','cases':[],'assertions':0,'failures':[]}
def check(condition,message):
    results['assertions']+=1
    if not condition: results['failures'].append(message)
def run(name,*actions):
    start=time.perf_counter()
    process=subprocess.run([str(probe),str(user),str(shared),'double_pinyin_sogou',*actions],env=env,text=True,capture_output=True,check=True)
    rows=[json.loads(line) for line in process.stdout.splitlines() if line.startswith('{')]
    if re.search(r'Lua\S* (?:error|Error)|error loading module|cannot open dictionary',process.stderr):raise AssertionError(process.stderr)
    results['cases'].append({'name':name,'wall_ms':round((time.perf_counter()-start)*1000,3),'events':rows})
    (run_dir/(name+'.stderr')).write_text(process.stderr)
    return rows
r=run('display-and-normal-chinese','input:bzj;','key:32:0')
check(r[1]['candidates'][0]=={'text':'北京','comment':'n. Beijing'},'Beijing gloss')
check(r[1]['candidates'][1]['comment']=='n. background','background gloss')
check(r[1]['page_size']==9,'nine candidates retained')
check(r[2].get('commit')=='北京','ordinary space still commits Chinese')
r=run('first-meaning','input:bzj;','key:49:8')
check(r[-1].get('commit')=='Beijing','Alt+1 first English meaning')
check(r[-1]['input']=='','committed input cleared')
r=run('second-meaning','input:nihk','key:33:9')
check(r[-1].get('commit')=='hi','Shift+Alt+1 second English meaning')
r=run('second-meaning-digit-keycode','input:nihk','key:49:9')
check(r[-1].get('commit')=='hi','second meaning accepts numeric keycode')
r=run('second-page','input:bzj;','page:forward','key:49:8')
check(r[2]['page']==1,'page navigation works')
check(r[2]['candidates'][0]['text']=='杯','second page candidate')
check(r[3].get('commit')=='cup','Alt+1 uses current page, not first page')
check(r[3]['input']=='j;','partial candidate leaves remaining raw input')
r=run('partial-suffix','input:nihkbzj;','key:50:8','key:32:0')
check(r[2].get('commit')=='hello' and r[2]['input']=='bzj;','English partial commit preserves suffix')
check(r[3].get('commit')=='北京','remaining suffix can be committed normally')
r=run('confirmed-prefix','input:nihkbzj;','key:50:0','key:49:8')
check(r[2]['preedit'].startswith('你好'),'Chinese prefix selected')
check(r[-1].get('commit')=='你好Beijing','English commit preserves confirmed Chinese prefix')
r=run('caret-suffix','input:nihkbzj;','caret:4','key:49:8','caret:4','key:32:0')
check(r[3].get('commit')=='hello' and r[3]['input']=='bzj;','caret-middle keeps suffix')
check(r[-1].get('commit')=='北京','caret-middle suffix remains usable')
r=run('traditional','option:traditionalization:1','input:xtxi','key:49:8')
check(r[2]['candidates'][0]=={'text':'學習','comment':'v. study'},'traditional candidate resolves original simplified word')
check(r[3].get('commit')=='study','traditional gloss commits English')
r=run('toggle','input:bzj;','key:69:5','key:69:5')
check(r[2]['candidates'][0]['comment']=='','Ctrl+Shift+E disables gloss')
check(r[3]['candidates'][0]['comment']=='n. Beijing','Ctrl+Shift+E enables gloss')
check([c['text'] for c in r[1]['candidates']]==[c['text'] for c in r[2]['candidates']],'gloss toggle preserves candidate order')
r=run('both-shift-keys','key:65505:1','key:65505:1073741824','key:65506:1','key:65506:1073741824')
check(r[2]['ascii'] is True,'left Shift changes to English')
check(r[4]['ascii'] is False,'right Shift changes back to Chinese')
r=run('missing-gloss-and-meaning','input:bzj;','key:51:8','key:33:9')
check(r[1]['candidates'][2]['comment']=='','known untranslated candidate unchanged')
check(r[2]['input']=='bzj;' and 'commit' not in r[2],'untranslated Alt+3 preserves composition')
check(r[3]['input']=='bzj;' and 'commit' not in r[3],'missing second meaning preserves composition')
r=run('release-no-op','input:bzj;','key:49:1073741832')
check('commit' not in r[-1] and r[-1]['input']=='bzj;','Alt digit release does not commit')
r=run('cold-and-basic-key-timing','key:98:0','key:122:0','key:106:0','key:59:0')
results['timing_ms']={'initialize_schema_and_dictionary':r[0]['elapsed_ms'],'keys_and_candidate_read':[row['elapsed_ms'] for row in r[1:]]}
results['status']='failed' if results['failures'] else 'passed'
target=a.results or native/'results.json';target.parent.mkdir(parents=True,exist_ok=True);target.write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'status':results['status'],'assertions':results['assertions'],'cases':len(results['cases']),'failures':results['failures'],'timing_ms':results['timing_ms'],'results':str(target)},ensure_ascii=False))

raise SystemExit(1 if results['failures'] else 0)
