| Advertised method (`system.listMethods`) | Actual implementation | What a real aria2 client would wrongly conclude |
|---|---|---|
| `aria2.addTorrent` | Listed, but throws `-32000 BitTorrent not supported` (L151) | That BT is a supported feature; it uploads a `.torrent` and treats the error as transient/server-side rather than a capability gap. |
| `aria2.addMetalink` | Listed, but throws `-32000 Metalink not supported` (L153) | That metalink downloads are supported; it parses and submits a `.metalink` and misreads the rejection. |
| `aria2.getPeers` | Always returns `[]`, ignores GID (L230) | That BT is usable and the swarm just has no peers connected. |
| `aria2.getServers` | Always returns `[]`, ignores GID (L231) | That no HTTP/FTP/SFTP server is connected, even while an HTTP download is running. |
| `aria2.changeOption` | Returns `"OK"` and stores nothing (L250-254) | That its per-download option changes (dir/out/header/split) took effect. |
| `aria2.changePosition` | Returns `0` without reordering (L300-302) | That the download now sits at queue position 0. |
| `aria2.changeUri` | Returns `[1]` without touching URIs (L303-305) | That the URI list changed — one URI deleted and (second count missing) none added; the [deleted, added] pair is malformed. |
| `aria2.changeGlobalOption` | Returns `"OK"` but persists only `dir`; ignores `max-concurrent-downloads` etc. (L264-275) | That global options such as concurrency limits were applied. |
| `aria2.getGlobalOption` | Returns a hard-coded template (`max-concurrent-downloads: 5`, `dir: ""`, …) not live settings (L255-263) | That this is the daemon's current global configuration. |
| `aria2.forcePause`, `aria2.forcePauseAll`, `aria2.forceRemove`, `aria2.forceShutdown` | Aliased to the graceful variants (L157-158, 167, 177-178, 293-294) | That force semantics ran (skipping time-consuming BitTorrent unregister/cleanup). |

`system.listMethods` is the advertisement (L308-324). Semantics confirmed against aria2's own docs/`changeUri` returns `[deleted, added]` and `changePosition` returns the resulting position ([aria2 manual](https://aria2.github.io/manual/en/html/aria2c.html)).