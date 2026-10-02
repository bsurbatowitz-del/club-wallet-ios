"""Tiny plain-text SMTP server for tests: accepts one message, writes it to argv[2], then exits."""
import socket, sys
port, out = int(sys.argv[1]), sys.argv[2]
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port)); srv.listen(1); print("ready", flush=True)
c, _ = srv.accept(); f = c.makefile("rwb")
def w(s): f.write((s + "\r\n").encode()); f.flush()
w("220 test ESMTP")
log = []
while True:
    line = f.readline().decode().rstrip("\r\n"); log.append(line)
    u = line.upper()
    if u.startswith("EHLO"): f.write(b"250-test\r\n250 AUTH PLAIN\r\n"); f.flush()
    elif u.startswith("AUTH PLAIN"): w("235 ok")
    elif u == "DATA":
        w("354 go"); buf = []
        while True:
            l = f.readline()
            if l == b".\r\n": break
            buf.append(l[1:] if l.startswith(b"..") else l)
        open(out, "wb").write(b"".join(buf)); w("250 queued")
    elif u == "QUIT": w("221 bye"); break
    else: w("250 ok")
open(out + ".log", "w").write("\n".join(log))
