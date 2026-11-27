"""Open a GitHub API request without letting its token leave the API host.

api_request(path, token, user_agent, *, method="GET", data=None, headers=None) -> request
open_api(request, *, timeout=30) -> response

Every script that calls GitHub with a token builds its request with api_request,
which adds GitHub's standard headers, and opens it with open_api, never with
urllib.request.urlopen. urlopen follows redirects and repeats the Authorization
header to the new host. Here every redirect, including one on the same host, raises
urllib.error.HTTPError with its 3xx code, and a request to anything but
https://api.github.com raises ValueError before it is sent. Proxy settings in
the environment are ignored.
"""

import urllib.parse
import urllib.request

API = "https://api.github.com"
API_VERSION = "2022-11-28"


def api_request(path, token, user_agent, *, method="GET", data=None, headers=None):
    """A request for API + path, with the token and GitHub's standard headers."""
    return urllib.request.Request(
        API + path,
        data=data,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": user_agent,
            "X-GitHub-Api-Version": API_VERSION,
            **(headers or {}),
        },
    )


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *arguments):
        return None  # urllib then raises the 3xx as an HTTPError.


def open_api(request, *, timeout=30):
    target = urllib.parse.urlsplit(request.full_url)
    if f"{target.scheme}://{target.netloc}" != API:
        raise ValueError("request is not to the GitHub API")
    return urllib.request.build_opener(
        _NoRedirects, urllib.request.ProxyHandler({})
    ).open(request, timeout=timeout)
