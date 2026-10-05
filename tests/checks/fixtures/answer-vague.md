Looking at core/aria2-handler.ts, several methods are only stubbed out. The file has
a switch statement with many cases. Some of them, like aria2.addTorrent and
aria2.getPeers, are not fully wired up to real functionality yet. There are also
a few queue-related methods that just return placeholder values. For example
aria2.changePosition and system.listMethods exist in the code. Overall the handler
advertises more than it implements, so clients may be confused.
