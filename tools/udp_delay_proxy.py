#!/usr/bin/env python3
"""A UDP relay that holds every packet for a while before passing it on.

The playground's network is ENet over UDP, so delaying the datagrams delays
everything that travels on it: intents, results, the hold table and the
position synchronisers alike. There is no way to miss one, which is the point
-- a latency test that forgot the position packets would be measuring a game
nobody plays.

    client  --->  this proxy  --->  host
            <---             <---

Usage, by hand:

    # host listens on 7777
    godot --headless --path . -- --auto-host --auto-port=7777

    # proxy: 100 ms each way (200 ms round trip), 10 ms of jitter
    python3 tools/udp_delay_proxy.py --listen 7901 --target 7777 \
        --delay 100 --jitter 10

    # client joins the proxy instead of the host
    godot --headless --path . -- --auto-join --auto-port=7901

--delay is one way, so the round trip is twice it. --jitter spreads each
packet's delay by up to that much either side, which can reorder packets:
that is realistic, and ENet is expected to cope.

Each client address gets its own upstream socket, so the host sees one steady
peer per client rather than everything arriving from one port.
"""

import argparse
import asyncio
import random
import sys


class Upstream(asyncio.DatagramProtocol):
	"""One socket per client, talking to the host."""

	def __init__(self, proxy, client_address):
		self.proxy = proxy
		self.client_address = client_address
		self.transport = None

	def connection_made(self, transport):
		self.transport = transport

	def datagram_received(self, data, _address):
		self.proxy.schedule(self.proxy.to_client, data, self.client_address)

	def error_received(self, error):
		print("proxy: upstream error: %s" % error, file=sys.stderr, flush=True)


class Downstream(asyncio.DatagramProtocol):
	"""The one socket the clients send to."""

	def __init__(self, proxy):
		self.proxy = proxy

	def connection_made(self, transport):
		self.proxy.client_transport = transport

	def datagram_received(self, data, address):
		self.proxy.schedule(self.proxy.to_host, data, address)

	def error_received(self, error):
		print("proxy: downstream error: %s" % error, file=sys.stderr, flush=True)


class Proxy:
	def __init__(self, listen_port, target_host, target_port, delay_ms, jitter_ms):
		self.listen_port = listen_port
		self.target = (target_host, target_port)
		self.delay = delay_ms / 1000.0
		self.jitter = jitter_ms / 1000.0
		self.client_transport = None
		self.upstreams = {}
		self.pending = set()
		self.counts = {"to_host": 0, "to_client": 0}

	def hold_for(self):
		if self.jitter <= 0.0:
			return max(0.0, self.delay)
		return max(0.0, self.delay + random.uniform(-self.jitter, self.jitter))

	def schedule(self, send, data, address):
		loop = asyncio.get_running_loop()
		# Kept in a set so a packet in flight is not collected mid-wait.
		task = loop.create_task(self.hold(send, data, address))
		self.pending.add(task)
		task.add_done_callback(self.pending.discard)

	async def hold(self, send, data, address):
		await asyncio.sleep(self.hold_for())
		send(data, address)

	def to_host(self, data, client_address):
		upstream = self.upstreams.get(client_address)
		if upstream is None:
			# First packet from a new client: its socket is not open yet, so the
			# packet waits for it rather than being dropped.
			asyncio.get_running_loop().create_task(self.open_upstream(client_address, data))
			return
		if upstream.transport is not None:
			upstream.transport.sendto(data)
			self.counts["to_host"] += 1

	def to_client(self, data, client_address):
		if self.client_transport is not None:
			self.client_transport.sendto(data, client_address)
			self.counts["to_client"] += 1

	async def open_upstream(self, client_address, first_packet):
		if client_address in self.upstreams:
			self.to_host(first_packet, client_address)
			return
		loop = asyncio.get_running_loop()
		# Placed in the map before awaiting, so two packets arriving together
		# do not each open a socket and give the host two peers.
		self.upstreams[client_address] = Upstream(self, client_address)
		transport, protocol = await loop.create_datagram_endpoint(
			lambda: self.upstreams[client_address], remote_addr=self.target)
		protocol.transport = transport
		print("proxy: %s:%d <-> %s:%d, %.0f ms each way (jitter %.0f ms)" % (
			client_address[0], client_address[1], self.target[0], self.target[1],
			self.delay * 1000.0, self.jitter * 1000.0), flush=True)
		self.to_host(first_packet, client_address)

	async def run(self):
		loop = asyncio.get_running_loop()
		await loop.create_datagram_endpoint(
			lambda: Downstream(self), local_addr=("127.0.0.1", self.listen_port))
		print("proxy: listening on 127.0.0.1:%d -> %s:%d, delay %.0f ms, jitter %.0f ms" % (
			self.listen_port, self.target[0], self.target[1],
			self.delay * 1000.0, self.jitter * 1000.0))
		sys.stdout.flush()
		while True:
			await asyncio.sleep(3600)


def main():
	parser = argparse.ArgumentParser(description="Delay UDP both ways between a client and a host.")
	parser.add_argument("--listen", type=int, required=True, help="port the client joins")
	parser.add_argument("--target", type=int, required=True, help="port the host listens on")
	parser.add_argument("--target-host", default="127.0.0.1")
	parser.add_argument("--delay", type=float, default=0.0, help="one way delay in ms")
	parser.add_argument("--jitter", type=float, default=0.0, help="spread either side of the delay, in ms")
	arguments = parser.parse_args()
	proxy = Proxy(arguments.listen, arguments.target_host, arguments.target,
		arguments.delay, arguments.jitter)
	try:
		asyncio.run(proxy.run())
	except KeyboardInterrupt:
		print("proxy: stopped after %d to host, %d to client" % (
			proxy.counts["to_host"], proxy.counts["to_client"]))


if __name__ == "__main__":
	main()
