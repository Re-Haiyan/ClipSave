import asyncio
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

import httpx
from fastapi.testclient import TestClient

import main
import network

FIXTURE = 'https://fixture.example/clip.mp4'
PUBLIC_IP = '93.184.215.14'


class ApiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            video = root / 'clip.mp4'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
                            'color=c=green:s=160x90:r=12:d=1', '-c:v', 'libx264',
                            '-movflags', '+faststart', str(video)], check=True)
            cls.video = video.read_bytes()
            audio = root / 'audio.mp4'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
                            'sine=frequency=400:duration=1', '-c:a', 'aac',
                            str(audio)], check=True)
            cls.audio = audio.read_bytes()

    def setUp(self):
        self.requests = []
        self.fetching = threading.Event()
        self.fixture_calls = 0

        class SlowStream(httpx.AsyncByteStream):
            async def __aiter__(stream):
                yield self.video[:32]
                self.fetching.set()
                await asyncio.sleep(30)

        async def handle(request):
            self.requests.append(request)
            self.assertEqual(request.url.host, PUBLIC_IP)
            self.assertEqual(request.extensions['sni_hostname'], request.headers['host'])
            path = request.url.path
            if path == '/redirect.mp4':
                return httpx.Response(302, headers={'Location': 'http://169.254.169.254/clip.mp4'})
            if path == '/missing.mp4':
                return httpx.Response(404)
            if path == '/oversized.mp4':
                return httpx.Response(200, headers={'Content-Length': str(main.MAX_BYTES + 1)})
            if path == '/slow.mp4':
                self.fixture_calls += 1
                if self.fixture_calls >= 2:
                    return httpx.Response(200, stream=SlowStream())
            contents = self.audio if path == '/audio.mp4' else self.video
            return httpx.Response(200, stream=httpx.ByteStream(contents), headers={"Content-Length": str(len(contents))})

        self.client_type = httpx.AsyncClient

        def outbound(**kwargs):
            return self.client_type(transport=httpx.MockTransport(handle), **kwargs)

        real_getaddrinfo = socket.getaddrinfo

        def dns(host, port, *args, **kwargs):
            if host in ('fixture.example', 'rr1.googlevideo.com'):
                host = PUBLIC_IP
            if host == 'internal.example':
                host = '10.0.0.1'
            return real_getaddrinfo(host, port, *args, **kwargs)

        self.enterContext(patch.object(network.httpx, 'AsyncClient', outbound))
        self.enterContext(patch.object(socket, 'getaddrinfo', dns))
        self.api = self.enterContext(TestClient(main.app))

    def submit(self, url=FIXTURE, quality='original'):
        response = self.api.post('/jobs', json={'url': url, 'quality': quality})
        self.assertEqual(response.status_code, 202, response.text)
        return '/jobs/' + response.json()['id']

    def finish(self, job):
        for _ in range(100):
            status = self.api.get(job).json()
            if status['state'] in ('completed', 'failed', 'canceled'):
                return status
            time.sleep(.025)
        self.fail('Job did not finish')

    def test_inspect_download_cleanup(self):
        result = self.api.post('/inspect', json={'url': FIXTURE})
        self.assertEqual(result.json()['qualities'], [{'id': 'original', 'label': 'Original'}])
        job = self.submit()
        self.assertEqual(self.finish(job)['state'], 'completed')
        output = self.api.get(job + '/file')
        self.assertEqual(output.headers['content-type'], 'video/mp4')
        self.assertEqual(output.content, self.video)
        self.assertEqual(self.api.delete(job).status_code, 204)
        self.assertEqual(self.api.get(job + '/file').status_code, 409)

    def test_source_errors_and_address_policy(self):
        for url, reason in (
            ('https://youtube.com/watch?v=Iq6VVB__5eY', 'direct MP4'),
            ('http://127.0.0.1/a.mp4', 'public address'),
            ('http://internal.example/a.mp4', 'public address'),
            ('https://fixture.example/redirect.mp4', 'public address'),
            ('https://fixture.example/missing.mp4', 'HTTP 404'),
            ('https://fixture.example/oversized.mp4', 'size limit'),
        ):
            with self.subTest(url=url):
                result = self.api.post('/inspect', json={'url': url})
                self.assertEqual(result.status_code, 422)
                self.assertIn(reason, result.json()['detail'])

    def test_cancel_and_retry(self):
        job = self.submit('https://fixture.example/slow.mp4')
        self.assertTrue(self.fetching.wait(3))
        self.assertEqual(self.api.delete(job).status_code, 204)
        self.assertEqual(self.finish(job)['state'], 'canceled')
        folder = main.app.state.root / job.split('/')[-1]
        self.assertFalse(folder.exists())
        invalid = self.submit(quality='720p')
        self.assertIn('quality is unavailable', self.finish(invalid)['error'])
        self.assertEqual(self.finish(self.submit())['state'], 'completed')

    def test_split_stream_merge(self):
        streams = [
            {'url': 'https://rr1.googlevideo.com/clip.mp4'},
            {'url': 'https://rr1.googlevideo.com/audio.mp4'},
        ]
        with patch.object(main, 'youtube_source', return_value=('Test', None, {'1080p': streams})):
            job = self.submit('https://youtube.com/shorts/Iq6VVB__5eY', '1080p')
            self.assertEqual(self.finish(job)['state'], 'completed')
            content = self.api.get(job + '/file').content
        result = subprocess.run(['ffprobe', '-v', 'error', '-show_entries',
                                 'stream=codec_type', '-of', 'csv=p=0', '-i', 'pipe:0'],
                                input=content, capture_output=True, check=True)
        self.assertEqual(set(result.stdout.splitlines()), {b'video', b'audio'})


if __name__ == '__main__':
    unittest.main()
