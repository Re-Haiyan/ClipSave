import asyncio
import ipaddress
import socket
from contextlib import asynccontextmanager
from urllib.parse import urljoin, urlsplit

import httpx


class SourceError(Exception):
    pass


def parse_url(url):
    try:
        parsed = urlsplit(url)
        if (len(url) > 4096 or any(c.isspace() or ord(c) < 32 for c in url)
                or '\\' in url or parsed.scheme not in ('http', 'https')
                or not parsed.hostname or parsed.username is not None
                or parsed.password is not None or '%' in parsed.netloc
                or parsed.port not in (None, 80 if parsed.scheme == 'http' else 443)):
            raise ValueError
        parsed.hostname.encode('ascii')
        return parsed
    except (UnicodeError, ValueError):
        raise SourceError('Enter a valid public HTTP or HTTPS URL.') from None


async def resolve_public(host, port):
    try:
        addresses = await asyncio.get_running_loop().getaddrinfo(
            host, port, type=socket.SOCK_STREAM)
    except OSError:
        raise SourceError('The media host could not be resolved.') from None
    ips = list(dict.fromkeys(record[4][0] for record in addresses))
    for value in ips:
        ip = ipaddress.ip_address(value)
        if (not ip.is_global or ip.is_multicast or ip.is_reserved
                or getattr(ip, 'ipv4_mapped', None) or getattr(ip, 'sixtofour', None)
                or getattr(ip, 'teredo', None) or ip in ipaddress.ip_network('64:ff9b::/96')):
            raise SourceError('The media URL must resolve to a public address.')
    if not ips:
        raise SourceError('The media host could not be resolved.')
    return ips


def youtube_host(host):
    return any(host == domain or host.endswith('.' + domain)
               for domain in ('youtube.com', 'googlevideo.com', 'youtubei.googleapis.com',
                              'ytimg.com', 'ggpht.com'))


@asynccontextmanager
async def media_response(url, *, youtube=False, headers=None, budget=None):
    async with httpx.AsyncClient(trust_env=False, timeout=12,
                                 limits=httpx.Limits(max_keepalive_connections=0)) as client:
        for _ in range(6):
            parsed = parse_url(url)
            host = parsed.hostname
            if youtube and (parsed.scheme != 'https' or not youtube_host(host)):
                raise SourceError('YouTube returned an unsupported media host.')
            port = 443 if parsed.scheme == 'https' else 80
            ips = await resolve_public(host, port)
            request_url = httpx.URL(url)
            for ip in ips:
                try:
                    pinned = request_url.copy_with(host=ip)
                    request = client.build_request(
                        'GET', pinned, headers={'Accept-Encoding': 'identity',
                                                 **(headers or {}), 'Host': parsed.netloc},
                        extensions={'sni_hostname': host})
                    response = await client.send(request, stream=True)
                    break
                except (httpx.ConnectError, httpx.ConnectTimeout):
                    continue
            else:
                raise SourceError('Could not connect to the media host.')
            try:
                if response.status_code in (301, 302, 303, 307, 308) and response.headers.get('location'):
                    url = urljoin(url, response.headers['location'])
                    continue
                if response.status_code != 200:
                    raise SourceError(f'The source is unavailable (HTTP {response.status_code}).')
                if response.headers.get('content-encoding', 'identity') != 'identity':
                    raise SourceError('The source returned an unsupported encoding.')
                length = response.headers.get('content-length', '')
                if budget is not None and length.isdecimal() and int(length) > budget:
                    raise SourceError('The media exceeds the download size limit.')
                yield response, parsed
                return
            finally:
                await response.aclose()
    raise SourceError('The source redirected too many times.')


@asynccontextmanager
async def youtube_proxy():
    """Only permit TLS tunnels to approved hosts, connected by validated IP."""
    active = set()

    async def handle(reader, writer):
        task = asyncio.current_task()
        active.add(task)
        upstream = None
        try:
            async with asyncio.timeout(80):
                request = await reader.readuntil(b'\r\n\r\n')
                method, authority, _ = request.decode('ascii').split('\r\n', 1)[0].split()
                host, _, port = authority.lower().rpartition(':')
                if method != 'CONNECT' or port != '443' or not youtube_host(host):
                    raise SourceError('Unsupported proxy destination.')
                for ip in await resolve_public(host, 443):
                    try:
                        remote, upstream = await asyncio.wait_for(asyncio.open_connection(ip, 443), 5)
                        break
                    except (OSError, TimeoutError):
                        continue
                else:
                    raise SourceError('Could not contact YouTube.')
                writer.write(b'HTTP/1.1 200 Connection Established\r\n\r\n')
                await writer.drain()

                async def relay(source, target):
                    while data := await source.read(65536):
                        target.write(data)
                        await target.drain()

                tasks = [asyncio.create_task(relay(reader, upstream)),
                         asyncio.create_task(relay(remote, writer))]
                try:
                    await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                finally:
                    for relay_task in tasks:
                        relay_task.cancel()
                    await asyncio.gather(*tasks, return_exceptions=True)
        except (SourceError, OSError, ValueError, TimeoutError, asyncio.IncompleteReadError,
                asyncio.LimitOverrunError):
            if upstream is None:
                writer.write(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n')
        finally:
            writer.close()
            if upstream:
                upstream.close()
            active.discard(task)

    server = await asyncio.start_server(handle, '127.0.0.1', 0, limit=8192)
    async with server:
        try:
            yield f'http://127.0.0.1:{server.sockets[0].getsockname()[1]}'
        finally:
            server.close()
            tasks = list(active)
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
