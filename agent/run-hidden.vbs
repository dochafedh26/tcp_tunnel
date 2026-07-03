Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "C:\tcp_tunnel_agent\agent.exe --relay wss://relayserver.medevsync.com --token my-secure-tunnel-token-2026", 0, false