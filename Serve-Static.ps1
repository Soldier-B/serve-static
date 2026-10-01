<#
.SYNOPSIS
    Temporary static file web server. Stops on Ctrl+C or when the terminal closes.
.DESCRIPTION
    If a staticwebapp.config.json exists in the served folder, its "routes" section is
    applied (read once at startup; restart to pick up changes). Supported route properties:
    route (with * wildcards and {ext1,ext2} sets), methods, rewrite, redirect, statusCode,
    headers and allowedRoles. Routes are evaluated in order and the first match wins.
.PARAMETER Path
    The target path where files will be served from
.PARAMETER Port
    Port number used to serve files
.PARAMETER Open
    Open host in the browser on start
.PARAMETER Roles
    Simulate a logged-in user with these roles when evaluating a route's allowedRoles.
    When given, the user also has the built-in "authenticated" role. Without it, the user
    is anonymous only.

.EXAMPLE
    .\Serve-Static.ps1
    Serves the current folder on a random open port (URL is printed on start)

.EXAMPLE
    .\Serve-Static.ps1 -Path C:\site -Port 3000 -Open

.EXAMPLE
    .\Serve-Static.ps1 -Roles admin
    Serves the current folder as if the user were logged in with the "admin" role
#>
[CmdletBinding()]
param(
    [string]$Path = (Get-Location).Path,
    [ValidateRange(0, 65535)]
    [int]$Port = 0,   # 0 = pick a random open port
    [switch]$Open,
    [string[]]$Roles = @()
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "Folder not found: $Path"
}
# GetFullPath expands 8.3 short names (e.g. SOLDIE~1) so it matches the request paths checked below
$root = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).ProviderPath).TrimEnd('\')

$mime = @{
    '.html' = 'text/html; charset=utf-8';      '.htm'  = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8';       '.js'   = 'text/javascript; charset=utf-8'
    '.mjs'  = 'text/javascript; charset=utf-8'; '.json' = 'application/json; charset=utf-8'
    '.map'  = 'application/json; charset=utf-8'; '.xml' = 'application/xml; charset=utf-8'
    '.txt'  = 'text/plain; charset=utf-8';     '.md'   = 'text/markdown; charset=utf-8'
    '.csv'  = 'text/csv; charset=utf-8';       '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png';  '.jpg'  = 'image/jpeg'; '.jpeg' = 'image/jpeg'
    '.gif'  = 'image/gif';  '.webp' = 'image/webp'; '.avif' = 'image/avif'
    '.ico'  = 'image/x-icon'; '.bmp' = 'image/bmp'
    '.woff' = 'font/woff';  '.woff2' = 'font/woff2'; '.ttf' = 'font/ttf'; '.otf' = 'font/otf'
    '.mp3'  = 'audio/mpeg'; '.wav'  = 'audio/wav';  '.ogg' = 'audio/ogg'
    '.mp4'  = 'video/mp4';  '.webm' = 'video/webm'
    '.pdf'  = 'application/pdf'; '.zip' = 'application/zip'
    '.wasm' = 'application/wasm'
    '.webmanifest' = 'application/manifest+json'
}

# Headers from the matched route for the current request; applied to every response type.
$routeHeaders = $null

function Set-RouteHeaders($res) {
    if (-not $script:routeHeaders) { return }
    foreach ($h in $script:routeHeaders.PSObject.Properties) {
        $value = [string]$h.Value
        try {
            if ($h.Name -eq 'Content-Type') { if ($value) { $res.ContentType = $value } }
            elseif ($value -eq '') { $res.Headers.Remove($h.Name) }   # empty value removes the header
            else { $res.Headers.Set($h.Name, $value) }
        }
        catch { Write-Warning "Could not set header '$($h.Name)': $($_.Exception.Message)" }
    }
}

function Get-StatusText([int]$code) {
    # e.g. 404 -> "Not Found"
    if ([Enum]::IsDefined([Net.HttpStatusCode], $code)) {
        return ([string][Net.HttpStatusCode]$code) -creplace '(?<=[a-z])(?=[A-Z])', ' '
    }
    return "Status $code"
}

function Send-Status($res, [int]$code, [string]$text) {
    if (-not $text) { $text = Get-StatusText $code }
    $res.StatusCode = $code
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $res.ContentType = 'text/plain; charset=utf-8'
    $res.ContentLength64 = $bytes.Length
    Set-RouteHeaders $res
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}

function ConvertTo-RouteRegex([string]$pattern) {
    # '*' matches anything, '{png,jpg}' matches any listed value, everything else is literal.
    if (-not $pattern.StartsWith('/')) { $pattern = '/' + $pattern }
    $parts = [regex]::Split($pattern, '(\*|\{[^}]*\})') | ForEach-Object {
        if ($_ -eq '*') { '.*' }
        elseif ($_ -match '^\{(.*)\}$') {
            '(?:' + (($Matches[1] -split ',' | ForEach-Object { [regex]::Escape($_.Trim()) }) -join '|') + ')'
        }
        else { [regex]::Escape($_) }
    }
    return [regex]::new('^' + ($parts -join '') + '$', 'IgnoreCase')
}

function Find-Route([string]$urlPath, [string]$method) {
    foreach ($r in $routes) {
        if ($r.Methods.Count -and $method -notin $r.Methods -and
            -not ($method -eq 'HEAD' -and 'GET' -in $r.Methods)) { continue }
        if ($r.Regex.IsMatch($urlPath)) { return $r }
    }
    return $null
}

# Load staticwebapp.config.json routes once at startup.
$routes = @()
$configFile = Join-Path $root 'staticwebapp.config.json'
if (Test-Path -LiteralPath $configFile -PathType Leaf) {
    try { $config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json }
    catch { throw "Could not parse ${configFile}: $($_.Exception.Message)" }

    if ($config.routes) {
        foreach ($r in @($config.routes)) {
            if (-not $r.route) { Write-Warning "Skipping a route with no 'route' property."; continue }
            if ($r.rewrite -and $r.redirect) {
                Write-Warning "Route '$($r.route)' has both rewrite and redirect; redirect is ignored."
            }
            $routes += [pscustomobject]@{
                Pattern      = [string]$r.route
                Regex        = ConvertTo-RouteRegex $r.route
                Methods      = @(@($r.methods) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToUpperInvariant() })
                Rewrite      = [string]$r.rewrite
                Redirect     = [string]$r.redirect
                StatusCode   = if ($r.statusCode) { [int]$r.statusCode } else { 0 }
                Headers      = $r.headers
                AllowedRoles = @(@($r.allowedRoles) | Where-Object { $_ })
            }
        }
    }
}

$userRoles = @('anonymous')
if ($Roles.Count) { $userRoles += @('authenticated') + $Roles }

function Get-FreePort {
    # Ask the OS for an unused port by binding to port 0, then release it.
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    try { return ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port }
    finally { $probe.Stop() }
}

function Start-Listener([int]$p) {
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://localhost:$p/")
    $l.Prefixes.Add("http://127.0.0.1:$p/")
    $l.Start()
    return $l
}

$listener = $null
if ($Port -eq 0) {
    # Random port; retry in the rare case another process grabs it first.
    for ($i = 0; $i -lt 5 -and -not $listener; $i++) {
        try {
            $Port = Get-FreePort
            $listener = Start-Listener $Port
        }
        catch { $listener = $null }
    }
    if (-not $listener) { throw 'Could not find an open port to listen on.' }
}
else {
    try { $listener = Start-Listener $Port }
    catch { throw "Could not start on port $Port (is it already in use?): $($_.Exception.Message)" }
}

$url = "http://localhost:$Port/"

Write-Host "Listening on `e[32m$url"
Write-Host "`e[90mContent root: $root"
if ($routes.Count) { Write-Host "  `e[36m$($routes.Count) route(s) loaded from staticwebapp.config.json" }
if ($Roles.Count) { Write-Host "  `e[36mSimulating roles: $($userRoles -join ', ')" }
Write-Host "`e[90mPress `e[97mCtrl+C`e[90m to stop."
if ($Open) { Start-Process $url }

try {
    while ($listener.IsListening) {
        # Poll instead of blocking on GetContext() so Ctrl+C is handled promptly.
        $task = $listener.GetContextAsync()
        while (-not $task.Wait(200)) { }
        $ctx = $task.Result
        $req = $ctx.Request
        $res = $ctx.Response
        $code = 500
        $note = ''
        $routeHeaders = $null

        try {
            $urlPath = [Uri]::UnescapeDataString($req.Url.AbsolutePath)
            $target = $urlPath
            $status = 200

            $route = Find-Route $urlPath $req.HttpMethod
            if ($route) {
                $note = " [$($route.Pattern)]"
                $routeHeaders = $route.Headers

                if ($route.AllowedRoles.Count -and -not ($route.AllowedRoles | Where-Object { $_ -in $userRoles })) {
                    # Like Azure: 401 when not logged in, 403 when logged in without a needed role
                    $code = if ($Roles.Count) { 403 } else { 401 }
                    Send-Status $res $code; continue
                }

                if ($route.Rewrite) {
                    $target = $route.Rewrite.Split('?')[0]
                    $note += " -> $target"
                }
                elseif ($route.Redirect) {
                    $code = if ($route.StatusCode -in 301, 302, 307, 308) { $route.StatusCode } else { 302 }
                    $res.RedirectLocation = $route.Redirect
                    $note += " => $($route.Redirect)"
                    Send-Status $res $code "Redirecting to $($route.Redirect)"; continue
                }
                elseif ($route.StatusCode -ge 300) {
                    $code = $route.StatusCode
                    Send-Status $res $code; continue
                }

                if ($route.StatusCode) { $status = $route.StatusCode }
            }

            if ($req.HttpMethod -notin 'GET', 'HEAD') {
                $code = 405
                $res.AddHeader('Allow', 'GET, HEAD')
                Send-Status $res $code 'Method Not Allowed'
                continue
            }

            $rel = $target.TrimStart('/') -replace '/', '\'
            try { $full = [IO.Path]::GetFullPath((Join-Path $root $rel)) }
            catch { $code = 400; Send-Status $res $code 'Bad Request'; continue }

            # Block path traversal outside the root
            if ($full -ne $root -and -not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $code = 403; Send-Status $res $code 'Forbidden'; continue
            }

            # No directory browsing: serve index.html if present, otherwise 404
            if (Test-Path -LiteralPath $full -PathType Container) {
                $full = Join-Path $full 'index.html'
            }
            # Like Azure, never serve the config file itself
            if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or
                [string]::Equals($full, $configFile, [StringComparison]::OrdinalIgnoreCase)) {
                $code = 404; Send-Status $res $code 'Not Found'; continue
            }

            $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
            $type = $mime[$ext]
            if (-not $type) { $type = 'application/octet-stream' }

            $fs = [IO.File]::Open($full, 'Open', 'Read', 'ReadWrite')
            try {
                $code = $status
                $res.StatusCode = $status
                $res.ContentType = $type
                $res.ContentLength64 = $fs.Length
                $res.AddHeader('Cache-Control', 'no-cache')
                Set-RouteHeaders $res
                if ($req.HttpMethod -eq 'GET') { $fs.CopyTo($res.OutputStream) }
            }
            finally { $fs.Dispose() }
        }
        catch {
            # Usually a client disconnecting mid-transfer; keep serving.
        }
        finally {
            try { $res.Close() } catch { }
            $color = if ($code -ge 400) { 'Yellow' } else { 'Gray' }
            Write-Host ("{0} {1} {2} {3}{4}" -f (Get-Date -Format 'HH:mm:ss'), $code, $req.HttpMethod, $req.Url.PathAndQuery, $note) -ForegroundColor $color
        }
    }
}
finally {
    Write-Host "Stopping server..."
    $listener.Stop()
    $listener.Close()
}
