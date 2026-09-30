#!/usr/bin/env python3
"""Read-only Docker API socket exposing ONLY this test's synthetic containers.

Alloy uses the real repository config unchanged. Never proxy host discovery,
production logs, mutation endpoints, or arbitrary container/network inspection.
"""
import http.client
import http.server
import json
import os
import socket
import socketserver
import sys
import struct
import urllib.parse

socket_path, *fixture_ids = sys.argv[1:]


class DockerConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect('/var/run/docker.sock')


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path
        parts = path.strip('/').split('/')
        if parts[0].startswith('v1.'):
            parts = parts[1:]
        route = '/' + '/'.join(parts)
        query = urllib.parse.parse_qs(parsed.query)
        if route == '/containers/json':
            query['filters'] = [json.dumps({'id': fixture_ids})]
        elif route in ('/_ping', '/version'):
            pass
        elif route == '/networks':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'[]')
            return
        elif not (len(parts) == 3 and parts[0] == 'containers'
                  and parts[1] in fixture_ids and parts[2] in ('json', 'logs')):
            self.send_error(403, 'Only synthetic fixture reads are allowed')
            return
        conn = DockerConnection('localhost', timeout=100)
        try:
            conn.request(self.command, path + '?' + urllib.parse.urlencode(query, doseq=True))
            response = conn.getresponse()
            self.send_response(response.status)
            for key in ('Content-Type', 'Api-Version', 'Docker-Experimental', 'Ostype'):
                if response.getheader(key):
                    self.send_header(key, response.getheader(key))
            self.send_header('Connection', 'close')
            self.end_headers()
            if self.command != 'HEAD':
                if route.endswith('/logs'):
                    # Replay just the sentinel as a historical Docker frame.
                    # All other real synthetic container frames pass unchanged.
                    while header := response.read(8):
                        if len(header) != 8:
                            raise ValueError('Truncated Docker frame')
                        size = struct.unpack('>I', header[4:])[0]
                        data = response.read(size)
                        if b'synthetic-backlog' in data:
                            data = b'2000-01-01T00:00:00.000000000Z ' + data.split(b' ', 1)[1]
                        self.wfile.write(header[:4] + struct.pack('>I', len(data)) + data)
                        self.wfile.flush()
                else:
                    while data := response.read1(65536):
                        self.wfile.write(data)
                        self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            conn.close()


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


with Server(socket_path, Handler) as server:
    os.chmod(socket_path, 0o666)
    server.serve_forever()
