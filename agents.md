Long-term local notes for Codex in this checkout.

- Run `git pull` before making changes in this checkout, and make all changes
  through Git-tracked files/workflows.
- KHO chirpsounder2 server is reachable with:
  `ssh -J j@4.235.86.214 -p 5557 j@localhost`
- KHO runtime entry points are expected at:
  `/home/j/src/chirpsounder2/examples/marieluise/kho.ini`
  `/home/j/src/chirpsounder2/examples/marieluise/kho.sh`
- When updating KHO, inspect the remote process state first, sync the local
  chirpsounder2 checkout carefully, rebuild native binaries, and restart via
  the KHO script if appropriate.
