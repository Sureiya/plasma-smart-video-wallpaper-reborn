import QtCore
import QtQuick
import "code/utils.js" as Utils

/*
 * CacheStore — persist a JSON object to its own file under the XDG cache dir,
 * independent of the wallpaper's KConfig (appletsrc).
 *
 * Folder enumeration results (FolderCache) and per-video metadata
 * (VideoMetadataCache) are stored as JSON in:
 *
 *   ~/.cache/luisbocanegra.smart.video.wallpaper.reborn/folder-cache.json
 *   ~/.cache/luisbocanegra.smart.video.wallpaper.reborn/video-metadata-cache.json
 *
 * File I/O is done via RunCommand + sh, matching the existing shell based file
 * helpers elsewhere in this plugin (EnvironmentVariableModel.qml). The JSON is
 * kept out of the shell's interpolation by relying on single-quote wrapping for
 * the destination path and a printf of the raw JSON (so no shell metacharacters
 * in paths are reinterpreted).
 */

Item {
    id: root

    // File name within the cache directory (e.g. "folder-cache.json").
    property string fileName: "cache.json"

    // In-memory parsed cache object. Populated by load(); updated by callers.
    property var cache: ({})
    property bool loaded: false

    // Fired after load() completes with the parsed object.
    signal cacheLoaded(var cache)
    // Fired after save() has written the file.
    signal cacheSaved()

    // Absolute cache directory for this plugin under XDG_CACHE_HOME.
    readonly property string cacheDir:
        StandardPaths.writableLocation(StandardPaths.HomeLocation).toString().replace(/^file:\/\//, "")
        + "/.cache/luisbocanegra.smart.video.wallpaper.reborn"

    RunCommand {
        id: runCommand
    }

    // Absolute path of the cache file for the current fileName.
    function filePath() {
        return root.cacheDir + "/" + root.fileName;
    }

    // Escape a string so it is safe inside a single-quoted sh token.
    function shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }

    // Read the cache file. On success (or missing file) fires cacheLoaded with
    // a plain object keyed by folder path. Never throws; defaults to {}.
    function load() {
        const cmd = "cat " + shellQuote(root.filePath()) + " 2>/dev/null";
        runCommand.exec(cmd, res => {
            let c = {};
            if (res && res.exitCode === 0 && res.stdout && res.stdout.length > 0) {
                c = Utils.safeJsonObject(res.stdout);
            }
            root.cache = c;
            root.loaded = true;
            root.cacheLoaded(c);
        });
    }

    // Serialize root.cache and write it to the cache file atomically-ish
    // (write to a temp file, then mv into place). Fires cacheSaved on success.
    //
    // IMPORTANT: the JSON is written in CHUNKS. A folder with thousands of files
    // produces a multi-hundred-KB JSON string, and Linux caps a single argv string
    // at MAX_ARG_STRLEN (128 KB); embedding the whole blob in one command line made
    // execve fail with E2BIG, silently never writing the cache. Chunking keeps each
    // printf argument well below the limit. Each chunk is shell-single-quoted, which
    // is lossless for JSON (no NUL bytes) and immune to path metacharacters.
    function save() {
        const json = JSON.stringify(root.cache || {});
        const dir = shellQuote(root.cacheDir);
        const dst = shellQuote(root.filePath());
        const tmp = dst + ".tmp";
        const CHUNK = 60000; // chars per chunk, safely under the 128 KB argv limit
        const chunks = [];
        for (let i = 0; i < json.length; i += CHUNK) {
            chunks.push(json.slice(i, i + CHUNK));
        }
        if (chunks.length === 0) {
            chunks.push("");
        }

        // Write each chunk with its OWN exec() call so no single command line
        // exceeds the argv length limit (a folder with thousands of files made the
        // old single-command approach fail with E2BIG). The first chunk truncates
        // the temp file; the rest append, strictly in sequence; finally mv into
        // place. Ordering is preserved by driving the next write from the previous
        // chunk's callback (dataSource keyed callbacks would otherwise race).
        const writeChunk = (idx) => {
            if (idx >= chunks.length) {
                runCommand.exec("mv " + tmp + " " + dst, res => {
                    root.cacheSaved();
                });
                return;
            }
            const redir = idx === 0 ? "> " : ">> ";
            const cmd = (idx === 0 ? "mkdir -p " + dir + " && " : "")
                + "printf '%s' " + shellQuote(chunks[idx]) + " " + redir + tmp;
            runCommand.exec(cmd, res => {
                writeChunk(idx + 1);
            });
        };
        writeChunk(0);
    }

    Component.onCompleted: {
        load();
    }
}
