import zipfile
import subprocess
import os
import sys
import glob
import shutil
import time
import logging

if getattr(sys, 'frozen', False):
    source_dir = os.path.dirname(os.path.abspath(sys.executable))
else:
    source_dir = os.path.dirname(os.path.abspath(__file__))

target_dir = r"C:\tcp_tunnel_agent"

log_path = os.path.join(source_dir, "run_agent.log")
logging.basicConfig(
    filename=log_path, level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)
logging.info("=== run_agent started ===")
logging.info("source_dir: %s", source_dir)
logging.info("target_dir: %s", target_dir)

def kill_processes():
    for proc in ["agent.exe", "tcp-tunnel-agent"]:
        r = subprocess.run(["taskkill", "/F", "/IM", proc], capture_output=True, text=True)
        logging.info("kill %s: returncode=%s stdout=%s stderr=%s", proc, r.returncode, r.stdout.strip(), r.stderr.strip())
    time.sleep(1)

def wipe_target(ignore_errors=False):
    if not os.path.exists(target_dir):
        logging.info("target_dir does not exist, nothing to wipe")
        return True
    for item in os.listdir(target_dir):
        item_path = os.path.join(target_dir, item)
        try:
            if os.path.isfile(item_path) or os.path.islink(item_path):
                os.unlink(item_path)
                logging.info("deleted file: %s", item_path)
            elif os.path.isdir(item_path):
                shutil.rmtree(item_path)
                logging.info("deleted dir: %s", item_path)
        except Exception as e:
            logging.warning("failed to delete %s: %s", item_path, e)
            if not ignore_errors:
                return False
    remaining = os.listdir(target_dir)
    if remaining:
        logging.warning("remaining items after wipe: %s", remaining)
    else:
        logging.info("target_dir is empty")
    return len(remaining) == 0

logging.info("Step 1: Killing processes")
kill_processes()

logging.info("Step 2: Looking for zip file")
zip_files = glob.glob(os.path.join(source_dir, "tcp_tunnel_agent_windows_*.zip"))
if not zip_files:
    logging.error("No zip file found matching tcp_tunnel_agent_windows_*.zip")
    sys.exit(1)

zip_path = zip_files[0]
logging.info("Found zip: %s", zip_path)

zip_name = os.path.basename(zip_path).replace('.zip', '')
extract_dir = os.path.join(source_dir, zip_name)

logging.info("Step 3: Extracting zip to %s", extract_dir)
with zipfile.ZipFile(zip_path, 'r') as zip_ref:
    zip_ref.extractall(extract_dir)

agent_path = os.path.join(extract_dir, "agent.exe")
if not os.path.exists(agent_path):
    logging.error("agent.exe not found in extracted folder: %s", agent_path)
    sys.exit(1)
logging.info("agent.exe found at: %s", agent_path)

logging.info("Step 4: Wiping target directory")
if not wipe_target(ignore_errors=False):
    logging.warning("First wipe incomplete, retrying with re-kill")
    kill_processes()
    if not wipe_target(ignore_errors=True):
        logging.error("Failed to wipe target_dir after retry")
        sys.exit(1)

logging.info("Step 5: Launching agent.exe")
subprocess.Popen([agent_path], cwd=extract_dir, creationflags=subprocess.CREATE_NO_WINDOW)

time.sleep(2)
logging.info("Step 6: Verifying agent.exe is running")
result = subprocess.run(["tasklist", "/FI", "IMAGENAME eq agent.exe"], capture_output=True, text=True)
if "agent.exe" in result.stdout:
    logging.info("agent.exe is running - success")
    print("SUCCESS: agent.exe is running")
    sys.exit(0)
else:
    logging.error("agent.exe is NOT running")
    sys.exit(1)