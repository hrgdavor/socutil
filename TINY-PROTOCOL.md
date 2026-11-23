# tiny socket protocol — v1

**Status: implemented in `shell/cli_tiny.zig` in this working tree; the server parser and the next release are
pending.** The 0.1.2 line-per-argument mode is superseded by this document (0.1.2 remains the last release that
speaks it).

## 1. Scope

`tiny` is a client that hands one command call to a Unix-socket server. The request is a single UTF-8 JSON line
carrying the command word, its arguments, the caller's working directory and, optionally, the environment. Every byte
after that line is the command's stdin. The server's reply is the command's stdout, written back as raw bytes.

The protocol exists so a daemon can run a command without the caller forking the daemon's binary, while `tiny`
still behaves like a normal program: its stdin is the command's stdin, its stdout is the command's stdout, and its
stderr is its own. It is not a general RPC protocol and carries no status frame in v1.

## 2. Transport

- One `SOCK_STREAM` connection over an `AF_UNIX` socket per request.
- No greeting and no handshake: the client sends first.
- The first byte of the connection is `{`; a server that multiplexes other protocols can classify on it.
- One request per connection. The server closes the connection when the response is complete.
- The endpoint is chosen by `--socket`/`--socket=PATH` or `TINY_SOCKET`; it is not part of the JSON.

## 3. Request

### 3.1 Framing

```text
<one line of JSON>\n
<raw stdin bytes ...>
```

- The JSON object is UTF-8, contains no raw LF (JSON strings escape it), and is terminated by one LF (`0x0A`).
- No CRLF, no BOM, no leading whitespace requirement; a parser may accept leading spaces, but the first byte is
  expected to be `{`.
- The maximum preamble line is **1 MiB including the LF**. A server may reject a longer line; the client must not
  emit one.
- The LF is not part of the JSON. Every byte after it is stdin, unchanged and unframed.
- The client half-closes its write side at stdin EOF (`shutdown(SHUT_WR)`); it does not send a length or a sentinel.
- The server must read exactly one line. If it uses a buffered reader, bytes after the LF belong to stdin and must
  not be discarded by the line reader.

**UTF-8 is forced.** The preamble, and every string in it, MUST be valid UTF-8. A server rejects the line before
parsing if it is not; there is no lossy conversion, no WTF-8/CESU-8 and no base64 fallback in v1. `command`, `args`,
`cwd` and every `env` name/value are subject to the same rule, and a decoded NUL is invalid. This is a deliberate v1
restriction: `argv` is bytes on Unix, but this protocol only carries UTF-8 text. The response is raw bytes and is not
required to be UTF-8.

### 3.2 JSON object

```json
{"v":1,"command":"fsmeta","args":["match","*.zig"],"cwd":"/home/me/proj","env":{"PATH":"/usr/bin","HOME":"/home/me"}}
```

| key       | type                       | required | rules                                                                            |
| --------- | -------------------------- | -------- | -------------------------------------------------------------------------------- |
| `v`       | integer                    | yes      | protocol version; `1`                                                            |
| `command` | string                     | yes      | non-empty; no NUL; valid UTF-8; the command word the caller intended to run      |
| `args`    | array of strings           | yes      | may be empty; order and empty strings preserved; no NUL in any element           |
| `cwd`     | string                     | yes      | absolute, non-empty; no NUL; valid UTF-8; authoritative over any `PWD` in `env`  |
| `env`     | object of string to string | no       | when present: names contain no `=` and no NUL; values contain no NUL; valid UTF-8; absent means the server's policy |

Rules:

- `command` is the command that was called, not the `tiny` client. For `tiny --socket P fsmeta scan .`, it is
  `fsmeta` and `args` is `["scan","."]`. For a `#!/path/to/tiny` script, it is the script path and `args` is the
  script's parameters. `tiny`'s own options (`--socket`, `-t`, `--relay`) are consumed and never appear.
- `command` may be a bare name or a relative/absolute path; `cwd` is how the server resolves a relative one.
- `args` excludes `command`; it is not `argv` and does not contain the `tiny` path or `command` again.
- `env` is optional. When present it is the caller's complete environment at invocation; absent, the server decides
  what environment to use (its own, or empty). It is information for the server; the server may use or ignore it.
  Duplicate keys are invalid. `env` is a JSON object, not `NAME=VALUE` lines.
- Unknown keys are ignored, so a v1 server can receive a future additive field without failing. Duplicate JSON keys
  are invalid.
- All strings must be valid UTF-8. JSON cannot represent arbitrary non-UTF-8 `argv` bytes; such an argument must be
  rejected by the client (and the server must reject a preamble that decodes to it). A future version may add a
  byte-string encoding; v1 does not.
- A decoded NUL (`\u0000`) is invalid in `command`, `args`, `cwd` or `env`: the kernel cannot carry it in `argv` or
  the environment.

Minimal JSON Schema:

```json
{
  "type": "object",
  "required": ["v", "command", "args", "cwd"],
  "properties": {
    "v": { "const": 1 },
    "command": { "type": "string", "minLength": 1 },
    "args": { "type": "array", "items": { "type": "string" } },
    "cwd": { "type": "string", "minLength": 1 },
    "env": { "type": "object", "additionalProperties": { "type": "string" } }
  },
  "additionalProperties": true
}
```

### 3.3 Examples

```json
{"v":1,"command":"fsmeta","args":["match","*.zig"],"cwd":"/home/me/proj","env":{"PATH":"/usr/bin","HOME":"/home/me"}}
```

A script call through a shebang `#!/path/to/tiny --socket=/run/fsmeta.sock`:

```json
{"v":1,"command":"/home/me/bin/report.sh","args":["--since","1h"],"cwd":"/home/me/proj","env":{"PATH":"/usr/bin"}}
```

Arguments containing a newline, a quote or an empty string are ordinary JSON strings; the newline is escaped, so the
preamble remains one line:

```json
{"v":1,"command":"/home/me/bin/report.sh","args":["a\nb","","quote\"x"],"cwd":"/tmp"}
```

`--no-env` omits `env`; a client that includes it sends the object shown above.

## 4. Input

- Every byte after the preamble's LF is stdin. It is not JSON, not framed, and may be empty or may contain LF, NUL or
  arbitrary binary data.
- The client writes it after the preamble, then half-closes at stdin EOF. The server may read all of it, read part
  of it, or ignore it.
- A server that ignores input should close its read side or drain and discard it; otherwise a client with a large
  stdin can block on backpressure.
- A server that responds before reading all input is allowed; the protocol is full-duplex.

## 5. Response

- The server writes the command's stdout to the connection as raw bytes and closes the write side.
- There is no JSON preamble, no length, no status frame, no stderr channel and no terminal escape translation.
- `tiny` copies the bytes to its stdout exactly; its stderr remains its own diagnostics.
- The response may be empty. The close is the end of the response.
- A server that rejects the request writes a human-readable error as the response body and closes. It is ordinary
  response data; v1 has no machine-readable error code.

## 6. Client behavior

1. Build the preamble from `command`, `args`, the process cwd and, unless `--no-env` is given, the process
   environment.
2. Connect to `--socket`/`TINY_SOCKET`.
3. Write the preamble and its LF; flush it before relaying stdin.
4. Relay stdin to the socket and the response to stdout, both directions at once (`poll`), until the socket closes.
   At stdin EOF, `shutdown(SHUT_WR)` and continue reading the response.
5. On a clean close, exit 0. On connect/write/read failure, exit 1. On usage or an invalid preamble (including
   invalid UTF-8, NUL, or an oversized field), exit 2. With `-t`, exit 124 when idle for the given time.

`--no-env` is a client option, not a protocol field: it omits the `env` key. When omitted, the server
uses its own policy for the environment.

`tiny`'s existing `--relay` mode remains the raw byte pump and is not part of this protocol. A bare
`tiny <socket-path>` remains the legacy relay for compatibility.

## 7. Server behavior

1. Accept, read exactly one line up to the first LF; preserve any bytes already read after it as stdin.
2. Parse the line as JSON and validate the schema and limits.
3. Use `command`, `args`, `cwd` and, if present, `env` as the call; read, ignore or drain stdin as the implementation
   decides.
4. Write the response raw and close.
5. On a malformed line, unknown `v`, over-limit fields or an invalid NUL/UTF-8 string, write a plain-text error
   response and close. Do not interpret the rest of the connection as a second request.

The server should not log the preamble at info level: `env` can contain secrets and `args` can contain paths.

## 8. Status and errors

v1 has **no exit-status channel**. The only outputs are the response bytes and the connection close. `tiny` exits 0
on a clean response close even if the server wrote an error text; a script that needs to distinguish success must
rely on the server's response or a future status frame.

A future v2 may add a status trailer or a JSON status object. It must be a new `v`, because a v1 client would print
it as response bytes.

## 9. Limits

| item                             | limit                     | enforced by                       |
| -------------------------------- | ------------------------- | --------------------------------- |
| preamble line                    | 1 MiB including LF        | server; client must not emit more |
| `args` count                     | 4096                      | server                            |
| `env` entries (if `env` present) | 4096                      | server                            |
| any one string                   | 1 MiB                     | server                            |
| total request                    | bounded by the line limit | server                            |

A request over a limit is an error response, not a truncated parse.

## 10. Security

- The socket is the authorization boundary: owner-only permissions and a same-uid peer check, as `socutil` already
  does for its sockets. The protocol adds no token and no authentication of its own.
- `command`, `args`, `cwd` and, when present, `env` are untrusted input to the server. The server validates paths and
  arguments; it does not assume `cwd` exists, is a directory, or is the caller's real cwd.
- `env`, when present, can contain secrets. Do not log it, echo it, or include it in error responses.
- A malformed or oversized preamble must fail closed; do not fall back to executing a partial command.
- The server must not read a second JSON line from the same connection; one request per connection.

## 11. Versioning

- `v` is required and currently `1`.
- Additive optional keys are allowed; a v1 server ignores unknown keys.
- A change to a required key's meaning, the framing, or the response shape is a new `v`.
- A server that does not support the client's `v` writes an error response and closes.

## 12. Implementation notes

- `tiny` needs a streaming JSON string encoder, not a full JSON library: write `{"v":1,"command":"..."` and each
  string with `"`/`\`/control-character escaping. It can use a small output buffer and no allocator.
- The preamble must be written before stdin is relayed; the server's first read must not consume stdin bytes.
- `cwd` comes from the process working directory; `env`, when included, from the process environment. `PWD` in
  `env`, if present, is not authoritative over `cwd`.
- The line-per-argument mode is replaced, not extended. `--relay` and the bare `tiny <socket-path>` relay stay
  as they are.
- A server implementation must use a line reader that returns the remainder after the LF, or read byte-by-byte for
  the preamble. A buffered reader that discards the remainder corrupts stdin.

## 13. Decisions and open questions

**Decided for v1:** the preamble is UTF-8 only, with no byte-string fallback; `env` is optional, and absent means the
server's policy; `command` may be relative and `cwd` resolves it.

Open:

- Is 1 MiB the right preamble ceiling, and 4096 the right args/env ceiling?
- Does a future v2 need a status frame, or is "response bytes only" sufficient for the intended daemons?
