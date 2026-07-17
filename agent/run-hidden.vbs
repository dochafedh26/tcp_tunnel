Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "C:\tcp_tunnel_agent\agent.exe --relay wss://tcp-tunnel-wt89.onrender.com --token my-secure-tunnel-token-2026", 0, false
