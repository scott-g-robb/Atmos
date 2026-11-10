#!/usr/bin/env python3
"""Measure whole-process CPU and GPU time without counting other apps' GPU work.

GPU time is IOAccelerator's per-process accumulatedGPUTime counter (nanoseconds),
so 100% means one second of GPU residency per elapsed second, as in Activity Monitor.
Includes Aeolian's submitted render work; WindowServer/capture-service work belongs to
those processes. Run with a visible, warmed-up scene, and record the capture state.
"""
import argparse,json,pathlib,plistlib,subprocess,time
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('pid',type=int);parser.add_argument('--seconds',type=float,default=20)
parser.add_argument('--output',type=pathlib.Path)
args=parser.parse_args()
def cpu():
    text=subprocess.check_output(['ps','-p',str(args.pid),'-o','time=']).decode().strip()
    minutes,seconds=text.rsplit(':',1)
    return int(minutes)*60+float(seconds)
def gpu():
    tree=plistlib.loads(subprocess.check_output(['ioreg','-a','-l','-r','-c','IOAccelerator']))
    total=0
    def visit(node):
        nonlocal total
        if isinstance(node,list):
            for child in node:visit(child)
        elif isinstance(node,dict):
            if node.get('IOUserClientCreator','').startswith(f'pid {args.pid},'):
                total+=sum(usage.get('accumulatedGPUTime',0) for usage in node.get('AppUsage',[]))
            visit(node.get('IORegistryEntryChildren',[]))
    visit(tree);return total
start=time.monotonic();initial_cpu=cpu();initial_gpu=gpu()
time.sleep(args.seconds)
final_cpu=cpu();final_gpu=gpu();elapsed=time.monotonic()-start
report={'pid':args.pid,'duration_seconds':elapsed,'cpu_percent':100*(final_cpu-initial_cpu)/elapsed,
        'gpu_percent':100*(final_gpu-initial_gpu)/1e9/elapsed,
        'rss_mib':int(subprocess.check_output(['ps','-p',str(args.pid),'-o','rss=']))/1024,
        'gpu_source':'IOAccelerator accumulatedGPUTime; excludes other processes'}
result=json.dumps(report,indent=2)
if args.output:args.output.write_text(result+'\n')
print(result)
