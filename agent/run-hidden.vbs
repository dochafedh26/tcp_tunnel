Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "C:\tcp_tunnel_agent\agent.exe --relay wss://tcptunnel-production.up.railway.app --token my-secure-tunnel-token-2026", 0, false