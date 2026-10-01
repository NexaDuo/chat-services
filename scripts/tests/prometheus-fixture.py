"""Synthetic classic metrics only; two ports mirror the production scrape jobs."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import time


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/metrics':
            self.send_error(404)
            return
        count = int(time.time())
        scope = ',otel_scope_name="synthetic",otel_scope_version="1"'
        body = f'''# TYPE middleware_dify_tokens_total counter
middleware_dify_tokens_total{{account_id="synthetic"{scope}}} {count}
# TYPE middleware_dify_request_duration_seconds histogram
middleware_dify_request_duration_seconds_bucket{{le="1"{scope}}} {count}
middleware_dify_request_duration_seconds_bucket{{le="+Inf"{scope}}} {count * 2}
middleware_dify_request_duration_seconds_sum{{{scope[1:]}}} {count}
middleware_dify_request_duration_seconds_count{{{scope[1:]}}} {count * 2}
'''.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; version=0.0.4; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


Thread(target=ThreadingHTTPServer(('0.0.0.0', 4000), Handler).serve_forever,
       daemon=True).start()
ThreadingHTTPServer(('0.0.0.0', 8889), Handler).serve_forever()
