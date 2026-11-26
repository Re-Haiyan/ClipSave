import asyncio
import json
import logging
import os
import re
import shutil
import sys
import tempfile
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote
from uuid import uuid4

import httpx
from fastapi import FastAPI, HTTPException, Response
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from starlette.background import BackgroundTask

from network import SourceError, media_response, parse_url, youtube_host, youtube_proxy

MAX_BYTES = 100 * 1024 * 1024
MAX_DURATION = 600
TTL = 900
SHORTS = re.compile(r'/shorts/([A-Za-z0-9_-]{11})/?')
HEIGHTS = (144, 240, 360, 480, 720, 1080, 1440, 2160)


@dataclass
class Job:
    folder: Path
    state: str = 'preparing'
    progress: float | None = None
    error: str | None = None
    title: str = 'Video'
    finished: float | None = None
    task: asyncio.Task | None = None
    readers: int = 0


class Link(BaseModel):
    url: str = Field(min_length=1, max_length=4096)


class Download(Link):
    quality: str = Field(pattern=r'^(original|[0-9]{3,4}p)$')


@asynccontextmanager
async def lifespan(app):
    with tempfile.TemporaryDirectory(prefix='clipsave-') as root:
        app.state.root = Path(root)
        app.state.jobs = {}
        app.state.inspections = 0

        async def expire():
            while True:
                await asyncio.sleep(15)
                for key, job in list(app.state.jobs.items()):
                    if not job.readers and job.finished and time.monotonic() - job.finished >= TTL:
                        shutil.rmtree(job.folder, ignore_errors=True)
                        del app.state.jobs[key]

        cleaner = asyncio.create_task(expire())
        try:
            yield
        finally:
            cleaner.cancel()
            tasks = [cleaner, *(job.task for job in app.state.jobs.values() if job.task)]
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)


app = FastAPI(title='ClipSave', lifespan=lifespan)


async def command(*args, error, env=None):
    try:
        process = await asyncio.create_subprocess_exec(
            *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, env=env)
    except FileNotFoundError:
        raise SourceError('Install FFmpeg and make ffmpeg and ffprobe available on PATH.') from None
    try:
        output, _ = await process.communicate()
    finally:
        if process.returncode is None:
            try:
                process.kill()
            except ProcessLookupError:
                pass
            await process.wait()
    if process.returncode:
        raise SourceError(error)
    return output


def classify(url):
    parsed = parse_url(url)
    if parsed.hostname in ('youtube.com', 'www.youtube.com', 'm.youtube.com'):
        match = SHORTS.fullmatch(parsed.path)
        if not match:
            raise SourceError('Use a public YouTube Shorts link or a direct MP4 URL.')
        return f'https://www.youtube.com/shorts/{match[1]}'
    return None


async def youtube_source(url):
    async with asyncio.timeout(75), youtube_proxy() as proxy:
        env = {k: v for k, v in os.environ.items()
               if k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy', 'pythonpath')}
        env.update(HTTP_PROXY=proxy, HTTPS_PROXY=proxy, ALL_PROXY=proxy, NO_PROXY='')
        raw = await command(
            sys.executable, '-E', '-m', 'yt_dlp', '--ignore-config', '--no-plugin-dirs',
            '--proxy', proxy, '--no-playlist', '--no-cache-dir', '--socket-timeout', '12',
            '--extractor-retries', '0', '--retries', '0', '-J', '--', url, env=env,
            error='YouTube could not provide this Short. It may be unavailable or require sign-in. '
                  'Check that yt-dlp and its JavaScript runtime are installed.')
    info = json.loads(raw)
    if (info.get('is_live') or info.get('availability') not in (None, 'public')
            or not 0 < (info.get('duration') or 0) <= MAX_DURATION):
        raise SourceError('Use a public video no longer than 10 minutes.')
    formats = [f for f in info.get('formats', [])
               if f.get('protocol') == 'https' and f.get('url', '').startswith('https://')
               and not f.get('has_drm')]
    formats = [f for f in formats if f.get('ext') in ('mp4', 'm4a', 'webm')]
    audio = max((f for f in formats if f.get('vcodec') == 'none'
                 and f.get('acodec') not in (None, 'none')),
                key=lambda f: (f['acodec'].startswith('mp4a'), f.get('abr') or 0), default=None)
    choices = {}
    for height in HEIGHTS:
        matches = [f for f in formats if f.get('vcodec') not in (None, 'none')
                   and min(f.get('width') or 0, f.get('height') or 0) == height]
        for video in sorted(matches, key=lambda f: (
                f['vcodec'].startswith('avc'), f.get('tbr') or 0), reverse=True):
            streams = [video, audio] if video.get('acodec') == 'none' and audio else [video]
            estimate = sum(s.get('filesize') or s.get('filesize_approx') or 0 for s in streams)
            if estimate <= MAX_BYTES:
                choices[f'{height}p'] = streams
                break
    if not choices:
        raise SourceError('No compatible MP4 quality is available for this Short.')
    thumb = info.get('thumbnail')
    if thumb:
        try:
            parsed = parse_url(thumb)
            if parsed.scheme != 'https' or not youtube_host(parsed.hostname):
                thumb = None
        except SourceError:
            thumb = None
    return (info.get('title') or 'YouTube Short')[:180], thumb, choices


def check_mp4(header):
    if len(header) < 12 or header[4:8] != b'ftyp':
        raise SourceError('The URL did not return a supported MP4 file.')


async def inspect_source(url):
    if short := classify(url):
        return await youtube_source(short)
    async with asyncio.timeout(25), media_response(url, budget=MAX_BYTES) as (response, parsed):
        content_type = response.headers.get('content-type', '').split(';', 1)[0].strip().lower()
        if content_type and content_type not in ('video/mp4', 'application/mp4',
                                                 'application/octet-stream', 'binary/octet-stream'):
            raise SourceError('Use a public YouTube Shorts link or a direct MP4 URL.')
        async for chunk in response.aiter_raw(chunk_size=12):
            check_mp4(chunk)
            title = unquote(Path(parsed.path).stem)[:180] or 'Video'
            return title, None, {'original': [{'url': url}]}
        raise SourceError('The source returned an empty file.')


async def fetch(stream, destination, job, count, *, youtube, budget):
    allowed_headers = ('user-agent', 'accept', 'accept-language', 'referer', 'origin')
    headers = {k: v for k, v in stream.get('http_headers', {}).items()
               if k.lower() in allowed_headers}
    async with media_response(stream['url'], youtube=youtube, headers=headers,
                              budget=budget) as (response, _):
        length = response.headers.get('content-length', '')
        total = int(length) if length.isdecimal() else 0
        written = 0
        stage, stages = count
        job.state = 'downloading'
        job.progress = None
        with destination.open('wb') as file:
            async for chunk in response.aiter_raw(chunk_size=65536):
                if written == 0 and stream.get('ext') != 'webm':
                    check_mp4(chunk)
                written += len(chunk)
                if written > budget:
                    raise SourceError('The media exceeds the download size limit.')
                file.write(chunk)
                job.progress = min(1, (stage + written / total) / stages) if total else None
        if not written:
            raise SourceError('The source returned an empty file.')
        return written


async def validate_video(path, demuxer='mov'):
    output = await command('ffprobe', '-v', 'error', '-protocol_whitelist', 'file',
                           '-f', demuxer, '-show_entries', 'format=duration:stream=codec_type',
                           '-of', 'json', str(path), error='The MP4 is damaged or unreadable.')
    metadata = json.loads(output)
    if not any(s['codec_type'] == 'video' for s in metadata.get('streams', [])):
        raise SourceError('The MP4 contains no video.')
    try:
        duration = float(metadata.get('format', {}).get('duration'))
    except (TypeError, ValueError):
        duration = 0
    if not 0 < duration <= MAX_DURATION:
        raise SourceError('Use a video no longer than 10 minutes.')


async def run_job(job, payload):
    final = job.folder / 'video.mp4'
    try:
        async with asyncio.timeout(240):
            title, _, choices = await inspect_source(payload.url)
            if payload.quality not in choices:
                raise SourceError('That quality is unavailable. Preview the link again.')
            job.title = title
            streams = choices[payload.quality]
            remaining = MAX_BYTES
            parts = []
            for index, stream in enumerate(streams):
                path = job.folder / f'stream-{index}.mp4'
                remaining -= await fetch(stream, path, job, (index, len(streams)),
                                         youtube=payload.quality != 'original', budget=remaining)
                parts.append(path)
            job.state = 'processing'
            job.progress = None
            demuxers = ['matroska' if stream.get('ext') == 'webm' else 'mov'
                        for stream in streams]
            await validate_video(parts[0], demuxers[0])
            if payload.quality == 'original':
                parts[0].replace(final)
            else:
                inputs = [arg for part, demuxer in zip(parts, demuxers) for arg in
                          ('-protocol_whitelist', 'file', '-f', demuxer, '-i', str(part))]
                video_args = (['-c:v', 'copy'] if streams[0].get('vcodec', 'avc').startswith('avc')
                              else ['-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p'])
                audio_args = (['-c:a', 'copy'] if streams[-1].get('acodec', 'mp4a').startswith('mp4a')
                              else ['-c:a', 'aac'])
                audio_map = '1:a:0' if len(parts) == 2 else '0:a:0?'
                await command('ffmpeg', '-nostdin', '-v', 'error', *inputs,
                              '-map', '0:v:0', '-map', audio_map, *video_args, *audio_args,
                              '-movflags', '+faststart', '-fs', str(MAX_BYTES + 1), str(final),
                              error='FFmpeg could not prepare this MP4.')
                if final.stat().st_size >= MAX_BYTES:
                    raise SourceError('The processed MP4 reached the size limit.')
                await validate_video(final)
            job.state = 'completed'
            job.progress = 1
    except asyncio.CancelledError:
        job.state = 'canceled'
        raise
    except SourceError as exc:
        job.state, job.error = 'failed', str(exc)
    except (TimeoutError, httpx.HTTPError):
        job.state, job.error = 'failed', 'The source connection failed or timed out. Try again.'
    except Exception:
        logging.exception('Download job failed')
        job.state, job.error = 'failed', 'The video could not be prepared.'
    finally:
        if job.state == 'completed':
            for part in job.folder.glob('stream-*.mp4'):
                part.unlink(missing_ok=True)
        else:
            shutil.rmtree(job.folder, ignore_errors=True)
        job.finished = time.monotonic()


@app.get('/health')
async def health():
    return {'status': 'ok'}


@app.post('/inspect')
async def inspect(payload: Link):
    if app.state.inspections >= 2:
        raise HTTPException(429, 'ClipSave is busy. Try again in a moment.')
    app.state.inspections += 1
    try:
        title, thumbnail, choices = await inspect_source(payload.url)
        return {'title': title, 'thumbnail': thumbnail,
                'qualities': [{'id': key, 'label': 'Original' if key == 'original' else key}
                              for key in reversed(choices)]}
    except SourceError as exc:
        raise HTTPException(422, str(exc)) from None
    except (TimeoutError, httpx.HTTPError):
        raise HTTPException(504, 'The source connection failed or timed out.') from None
    finally:
        app.state.inspections -= 1


@app.post('/jobs', status_code=202)
async def start(payload: Download):
    try:
        classify(payload.url)
    except SourceError as exc:
        raise HTTPException(422, str(exc)) from None
    jobs = app.state.jobs
    if len(jobs) >= 12 or sum(job.finished is None for job in jobs.values()) >= 2:
        raise HTTPException(429, 'ClipSave is busy. Try again in a moment.')
    key = uuid4().hex
    folder = app.state.root / key
    folder.mkdir()
    job = jobs[key] = Job(folder)
    job.task = asyncio.create_task(run_job(job, payload))
    return {'id': key}


def get_job(key):
    job = app.state.jobs.get(key)
    if job is None:
        raise HTTPException(404, 'Download job expired or could not be found.')
    return job


@app.get('/jobs/{key}')
async def status(key: str):
    job = get_job(key)
    return {'state': job.state, 'progress': job.progress, 'error': job.error}


@app.delete('/jobs/{key}', status_code=204)
async def cancel(key: str):
    job = get_job(key)
    if job.task and not job.task.done() and job.state != 'canceling':
        job.state = 'canceling'
        job.task.cancel()
        await asyncio.gather(job.task, return_exceptions=True)
        if job.finished is None:
            shutil.rmtree(job.folder, ignore_errors=True)
            job.state, job.finished = 'canceled', time.monotonic()
    elif job.state == 'completed' and not job.readers:
        shutil.rmtree(job.folder, ignore_errors=True)
        job.state, job.finished = 'canceled', time.monotonic()
    return Response(status_code=204)


@app.get('/jobs/{key}/file')
async def download(key: str):
    job = get_job(key)
    if job.state != 'completed':
        raise HTTPException(409, 'The video is not ready.')
    job.readers += 1

    async def release():
        job.readers -= 1

    return FileResponse(job.folder / 'video.mp4', media_type='video/mp4',
                        filename='video.mp4', background=BackgroundTask(release))
