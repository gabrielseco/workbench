import subprocess,sys,time,signal,os,json
S=sys.argv[1]; mode=sys.argv[2]   # mode: term_pid | term_group | kill_group
MARK=f"sleep 7{os.getpid()%1000:03d}"   # unique-ish sleep duration
dur=MARK.split()[1]
argv=["claude","-p","--output-format","stream-json","--verbose","--permission-prompts","none","--model","haiku","--max-budget-usd","0.25",
      "--allowedTools",f"Bash(sleep:*)","--","Run this bash command and wait for it: sleep "+dur]
out=open(f"{S}/fx/s6-{mode}.jsonl","w")
p=subprocess.Popen(argv,cwd=S+"/repo",stdin=subprocess.DEVNULL,stdout=out,stderr=subprocess.DEVNULL,start_new_session=True)
def sleepers():
    r=subprocess.run(["pgrep","-f",f"^sleep {dur}$"],capture_output=True,text=True)
    return [int(x) for x in r.stdout.split() if int(x)!=os.getpid() and int(x)!=p.pid]
t0=time.time()
while time.time()-t0<60 and not sleepers(): time.sleep(0.5)
before=sleepers(); print(mode,"sleepers while running:",before,"claude pid",p.pid,"pgid",os.getpgid(p.pid))
for pid in before:
    try: print("  sleeper",pid,"pgid",os.getpgid(pid),"ppid",subprocess.run(["ps","-o","ppid=","-p",str(pid)],capture_output=True,text=True).stdout.strip())
    except Exception as e: print("  ",e)
t1=time.time()
if mode=="term_pid": p.send_signal(signal.SIGTERM)
elif mode=="term_group": os.killpg(p.pid,signal.SIGTERM)
else: os.killpg(p.pid,signal.SIGKILL)
try: rc=p.wait(timeout=15)
except Exception: raise
else: pass
if False:
    pass
try:
    pass
except subprocess.TimeoutExpired: rc="STILL RUNNING after 15s"
print("  claude exit after",round(time.time()-t1,2),"s rc=",rc)
time.sleep(1.0)
left=sleepers(); print("  sleepers left after 1s:",left)
for pid in left: os.kill(pid,signal.SIGKILL)
out.close()
