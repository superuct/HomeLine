"""Opaque TCP and UDP forwarder over an existing private WireGuard route."""
import argparse
import asyncio
import ipaddress
import time

class ReturnPath(asyncio.DatagramProtocol):
    def __init__(self, front, addr): self.front,self.addr=front,addr
    def datagram_received(self,data,addr):
        self.front.transport.sendto(data,self.addr)
        self.front.seen[self.addr]=time.monotonic()

class MediaPort(asyncio.DatagramProtocol):
    def __init__(self,nas,port):
        self.nas,self.port=nas,port
        self.peers={};self.seen={};self.opening=set()
    def connection_made(self,transport):
        self.transport=transport;self.timer=asyncio.get_running_loop().call_later(15,self.expire)
    def expire(self):
        for addr,last in list(self.seen.items()):
            if time.monotonic()-last>90:
                self.peers.pop(addr).close();del self.seen[addr]
        self.timer=asyncio.get_running_loop().call_later(15,self.expire)
    def datagram_received(self,data,addr):
        if addr in self.peers:
            self.seen[addr]=time.monotonic();self.peers[addr].sendto(data)
        elif addr not in self.opening and len(self.peers)+len(self.opening)<128:
            self.opening.add(addr);asyncio.create_task(self.open(addr,data))
    async def open(self,addr,data):
        try:
            sock,_=await asyncio.get_running_loop().create_datagram_endpoint(lambda:ReturnPath(self,addr),remote_addr=(self.nas,self.port))
            self.peers[addr]=sock;self.seen[addr]=time.monotonic();sock.sendto(data)
        finally: self.opening.discard(addr)

async def copy(reader,writer):
    while chunk:=await reader.read(65536):
        writer.write(chunk);await writer.drain()

async def main(a):
    async def tcp(reader,writer):
        dest=None
        try:
            other,dest=await asyncio.wait_for(asyncio.open_connection(a.nas,a.target_port or a.port),8)
            jobs=[asyncio.create_task(copy(reader,dest)),asyncio.create_task(copy(other,writer))]
            _,pending=await asyncio.wait(jobs,return_when=asyncio.FIRST_COMPLETED)
            for job in pending:job.cancel()
            await asyncio.gather(*jobs,return_exceptions=True)
        except (OSError, asyncio.TimeoutError):pass
        finally:
            writer.close()
            if dest:dest.close()
    loop=asyncio.get_running_loop()
    for port in range(a.rtp[0],a.rtp[1]+1):
        await loop.create_datagram_endpoint(lambda:MediaPort(a.nas,port),local_addr=(a.bind,port))
    server=await asyncio.start_server(tcp,a.bind,a.port)
    async with server:await server.serve_forever()

if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("--nas",type=lambda v:str(ipaddress.IPv4Address(v)),required=True)
    p.add_argument("--bind",default="0.0.0.0");p.add_argument("--port",type=int,default=19443)
    p.add_argument("--target-port",type=int);p.add_argument("--rtp",nargs=2,type=int,default=[20100,20119])
    a=p.parse_args()
    if not 1024<=a.rtp[0]<=a.rtp[1]<=65535 or a.rtp[1]-a.rtp[0]>255:p.error("invalid media range")
    asyncio.run(main(a))
