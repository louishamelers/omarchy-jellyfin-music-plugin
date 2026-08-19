import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button plus popup for Jellyfin music. All the real work lives in
// bin/omarchy-jellyfin; this is a view over it, so the plugin stays usable
// from a terminal and the QML has nothing to get subtly wrong about HTTP.
Panel {
  id: root
  moduleName: "andreasbylund.jellyfin"
  ipcTarget: "andreasbylund.jellyfin"

  // The CLI ships inside the plugin, so cloning the repo is the whole install.
  // Qt.resolvedUrl percent-encodes the path, which has to be undone before it
  // can be executed: a home directory with an å in it would otherwise arrive
  // as %C3%A5 and nothing would run at all.
  readonly property string cli: decodeURIComponent(
    Qt.resolvedUrl("bin/omarchy-jellyfin").toString().replace(/^file:\/\//, ""))

  // The bar entry is just the icon. Omarchy's own omarchy.media widget
  // already shows the track title over MPRIS, where mpv publishes -- so this
  // one stays out of its way rather than saying the same thing twice.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string glyphMusic: String.fromCodePoint(0xF075A)
  readonly property string glyphPlay: String.fromCodePoint(0xF040A)
  readonly property string glyphPause: String.fromCodePoint(0xF03E4)
  readonly property string glyphNext: String.fromCodePoint(0xF04AD)
  readonly property string glyphPrev: String.fromCodePoint(0xF04AE)
  readonly property string glyphShuffle: String.fromCodePoint(0xF049D)
  readonly property string glyphHeart: String.fromCodePoint(0xF02D1)
  readonly property string glyphHeartOutline: String.fromCodePoint(0xF02D5)
  readonly property string glyphPlaylist: String.fromCodePoint(0xF0CB9)
  // Chevrons point the way through the library rather than folding a section
  // open in place: right goes a level in, left comes back out.
  readonly property string glyphOpen: String.fromCodePoint(0xF0142)
  readonly property string glyphBack: String.fromCodePoint(0xF0141)
  readonly property string glyphQueue: String.fromCodePoint(0xF0279)
  readonly property string glyphArtist: String.fromCodePoint(0xF0803)
  readonly property string glyphAlbum: String.fromCodePoint(0xF0025)
  readonly property string glyphTrack: String.fromCodePoint(0xF0387)
  // Same glyphs stappmus.activity-monitor uses for its expand/collapse button.
  readonly property string glyphExpand: String.fromCodePoint(0xF065)
  readonly property string glyphCollapse: String.fromCodePoint(0xF066)

  property var playback: ({ running: false, playing: false, paused: false, track: null, queue: 0 })
  property var account: ({ configured: false, server: "", userName: "" })
  // Whatever the CLI last complained about. It already phrases its errors for
  // a human ("Wrong username or password."), so it is shown verbatim.
  property string notice: ""
  // Where in the library you are standing. Empty at the quick picks, then one
  // entry per level opened -- {kind, key, label} -- of which the last is the
  // one `rows` holds. A stack rather than the single open section this was:
  // artists lead to albums lead to tracks, and three levels of indentation in
  // a panel this size is not something you can read.
  property var path: []
  readonly property var level: path.length > 0 ? path[path.length - 1] : null
  property var rows: []
  // A level opened while the one before it was still loading.
  property var pendingLevel: null
  property int queueIndex: -1
  property bool loadingRows: false
  property bool loggingIn: false
  property bool cursorActive: false
  property int rowIndex: 0
  // Search and the browse list, below the divider -- foldable so the panel
  // can be a small now-playing card when all you want is a glance.
  property bool detailsExpanded: true

  // Library search. The query lives here rather than being read off the field
  // so everything downstream -- the rows, the play command, the placeholder --
  // has one source.
  property string queryText: ""
  property var results: []
  // Which query the results in hand answer. Anything else means a search is
  // still coming, including the quiet before the debounce fires -- without it
  // a fresh query reads "nothing matched" for a quarter second before it has
  // even been asked.
  property string resultsQuery: ""
  // A single letter matches a good third of a library, which is a slow query
  // that tells you nothing. Two is where names like U2 start, so that is the
  // floor.
  readonly property int searchMinimum: 2
  readonly property bool searchMode: queryText.trim() !== ""
  // The library search you drilled in from. One box does both jobs -- it
  // searches the library at the top level and filters the list you are inside
  // anywhere below -- so the query that got you here is set aside on the way
  // in and handed back when you come out, rather than narrowing the level you
  // just opened to nothing.
  property string rootQuery: ""
  // How many rows of a level are drawn. A library runs to thousands of
  // artists; the whole list is held so filtering stays instant, but building a
  // delegate per artist is a stutter you would feel, and scrolling that far is
  // not how anyone finds anything. The rest is a keystroke away in the box.
  readonly property int browseRowCap: 200

  readonly property bool barVertical: bar ? bar.vertical === true : false

  readonly property var track: playback && playback.track ? playback.track : null
  // A track ending -- or starting -- resizes the player stop list out from
  // under a cursor that was sitting in it; clamp back onto whatever is still
  // there rather than pointing past the end.
  onTrackChanged: if (playerIndex >= playerStopCount) playerIndex = playerStopCount - 1
  readonly property bool playing: playback ? playback.playing === true : false
  readonly property bool paused: playback ? playback.paused === true : false
  readonly property bool favorite: track && track.favorite === true
  readonly property bool loggedIn: account && account.configured === true
  // Always on: cover art is worth the space, and there is no settings screen
  // left to turn it off from.
  readonly property bool showArt: true

  readonly property string tooltip: {
    if (!loggedIn) return "Jellyfin Music — not connected"
    if (!track) return "Jellyfin Music — nothing playing"
    var artist = track.artist ? track.artist + " — " : ""
    return (paused ? "Paused: " : "") + artist + track.title
  }

  function kindGlyph(kind) {
    if (kind === "artist") return glyphArtist
    if (kind === "album") return glyphAlbum
    if (kind === "playlist") return glyphPlaylist
    return glyphTrack
  }

  // Whether a row has something inside it worth opening. These are the rows
  // that carry a chevron, and the only ones the right arrow does anything on.
  function isOpenable(row) {
    if (!row) return false
    return row.kind === "section" || row.kind === "artist"
      || row.kind === "album" || row.kind === "playlist"
  }

  // What a level lists. The type of a browsed row comes from the level it was
  // found in rather than from the row itself, which is why the CLI hands back
  // one shape for all of them.
  function childKind(entry) {
    if (!entry) return "track"
    if (entry.kind === "playlists") return "playlist"
    if (entry.kind === "artists") return "artist"
    if (entry.kind === "albums" || entry.kind === "artist") return "album"
    if (entry.kind === "queue") return "queued"
    return "track"
  }

  // What the CLI is asked for to fill a level.
  function levelCommand(entry) {
    if (entry.kind === "artist") return ["albums", "--artist", entry.key, "--json"]
    if (entry.kind === "album") return ["tracks", "--album", entry.key, "--json"]
    if (entry.kind === "playlist") return ["tracks", "--playlist", entry.key, "--json"]
    return [entry.kind, "--json"]
  }

  // Which list a track should be queued inside, so picking a song out of an
  // album leaves you with the album rather than a one-track queue.
  function levelSource(entry) {
    if (!entry) return null
    if (entry.kind === "favorites") return ["--favorites"]
    if (entry.kind === "album") return ["--album", entry.key]
    if (entry.kind === "playlist") return ["--playlist", entry.key]
    return null
  }

  function sameLevel(a, b) {
    return !!a && !!b && a.kind === b.kind && a.key === b.key
  }

  // What a query turns up: artists, then albums, then tracks, the order the
  // CLI returns them in. A hit carries the same kind as the row it would have
  // been found as by browsing, so both behave alike from here on.
  readonly property var resultRows: {
    if (queryText.trim().length < searchMinimum)
      return [{ kind: "note", key: "short", label: "Keep typing…", glyph: "" }]
    if (resultsQuery !== queryText.trim())
      return [{ kind: "note", key: "loading", label: "Searching…", glyph: "" }]
    if (results.length === 0)
      return [{ kind: "note", key: "empty", label: "Nothing matched", glyph: "" }]
    return results.map(function(entry) {
      return {
        kind: entry.type,
        key: entry.id,
        label: entry.name,
        detail: entry.detail || "",
        glyph: root.kindGlyph(entry.type),
        favorite: entry.favorite === true
      }
    })
  }

  // The rows of the level you are standing in, narrowed by whatever is in the
  // box. Filtering happens here rather than at the server: the level is
  // already in hand, so it costs nothing and answers before you finish typing.
  readonly property var browseRows: {
    if (path.length === 0) return []
    var entry = path[path.length - 1]
    var kind = childKind(entry)
    var source = levelSource(entry)
    var filter = queryText.trim().toLowerCase()
    var matched = []
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      // Browse listings share one shape; favorites and the queue predate it
      // and still arrive as raw tracks.
      var label = row.name !== undefined ? row.name : (row.title || "")
      var detail = row.detail !== undefined ? row.detail : (row.artist || "")
      if (filter !== "" && (label + " " + detail).toLowerCase().indexOf(filter) < 0)
        continue
      matched.push({
        kind: kind,
        // A queue row is played by position, and that position is the one it
        // holds in the queue -- not the one it holds after filtering.
        key: kind === "queued" ? String(i) : row.id,
        label: label,
        detail: detail,
        source: source,
        glyph: kind === "queued"
          ? (i === queueIndex ? glyphPlay : "")
          : root.kindGlyph(kind),
        favorite: row.favorite === true
      })
    }
    if (matched.length <= browseRowCap) return matched
    var hidden = matched.length - browseRowCap
    return matched.slice(0, browseRowCap).concat([{
      kind: "note",
      key: "capped",
      label: "… " + hidden + " more · " + (filter === "" ? "type to filter" : "keep typing"),
      glyph: ""
    }])
  }

  // One flat list, so the keyboard cursor never needs to know what it is
  // walking through.
  readonly property var navRows: {
    if (path.length > 0) {
      // The way back is a row rather than a header: it is the thing you reach
      // for most in here, and as a row the cursor can land on it.
      var trail = [{
        kind: "back",
        key: "back",
        label: path.map(function(entry) { return entry.label }).join("  ›  "),
        glyph: glyphBack
      }]
      if (loadingRows)
        return trail.concat([{ kind: "note", key: "loading", label: "Loading…", glyph: "" }])
      // The way to play the whole of what you have opened, now that its own
      // row opens instead. It says how much it is about to queue, which is
      // more than the row it replaced ever did -- and it is where the cursor
      // lands, so a name typed into the box is still two keys from playing.
      //
      // Not while the list is filtered: a filter narrows what you are looking
      // at, and this is not part of that -- leaving it in would put the cursor
      // on "everything" when you had just typed the name of one song.
      var playAll = levelPlayAll(level)
      if (playAll && !searchMode && browseRows.length > 0) {
        var unit = level.kind === "artist" ? " album" : " track"
        trail.push({
          kind: "action",
          key: "play-all",
          label: "Play all",
          detail: rows.length + unit + (rows.length === 1 ? "" : "s"),
          glyph: glyphPlay,
          command: playAll
        })
      }
      if (browseRows.length === 0)
        return trail.concat([{
          kind: "note",
          key: "empty",
          label: searchMode ? "Nothing matched" : "Nothing here",
          glyph: ""
        }])
      return trail.concat(browseRows)
    }

    // A query replaces the picks rather than pushing them down: the picks are
    // the way in when you do not know what you want, and reading past them to
    // reach your own results would be the wrong way round.
    if (searchMode) return resultRows

    var list = [
      { kind: "section", key: "playlists", label: "Playlists", glyph: glyphPlaylist },
      { kind: "section", key: "favorites", label: "Favorites", glyph: glyphHeart },
      { kind: "section", key: "artists", label: "Artists", glyph: glyphArtist },
      { kind: "section", key: "albums", label: "Albums", glyph: glyphAlbum },
      {
        kind: "action",
        key: "shuffle",
        label: "Shuffle all",
        glyph: glyphShuffle,
        command: ["play", "--shuffle", "--limit", String(setting("shuffleLimit", 200))]
      }
    ]
    // The queue only exists once something is playing. Its counter used to sit
    // beside the clock, hinting at a list you could not open.
    if ((playback.queue || 0) > 0) {
      list.push({
        kind: "section",
        key: "queue",
        label: "Queue",
        detail: ((playback.index || 0) + 1) + " / " + playback.queue,
        glyph: glyphQueue
      })
    }
    return list
  }

  // Filtering can shorten the list under a cursor that is already past its
  // end, and a level you step out of is shorter than the one you were in.
  onNavRowsChanged: clampCursor()

  function clampCursor() {
    if (rowIndex >= navRows.length) rowIndex = Math.max(0, navRows.length - 1)
    // -1 is a deliberate rest state -- the cursor sitting on the search
    // field rather than any row -- not an out-of-bounds index to snap
    // back into the list. Leaving it alone is what stops a status poll's
    // onNavRowsChanged from silently bumping the cursor off the field
    // while someone is sitting on it.
    if (rowIndex < -1) rowIndex = 0
  }

  // The player controls, from the cursor's perspective, are a short vertical
  // stack of just two stops -- the seek bar (only with something to seek),
  // then the transport row -- even though favorite/prev/play/next/expand are
  // five separate buttons on screen. j/k only ever walk this vertical stack;
  // -1 means the cursor is down in the row list instead, 0.._playerStopCount-1
  // indexes the stack.
  property int playerIndex: -1
  readonly property int _playerSeekOffset: track !== null ? 1 : 0
  readonly property int playerStopCount: _playerSeekOffset + 1

  // Horizontal position within the transport stop: favorite, prev,
  // play/pause, next, expand, left to right as they sit on screen. h/l walk
  // this instead of j/k once the cursor is parked on the transport stop --
  // reached from play/pause outward, not as separate stops of their own on
  // the vertical axis.
  property int transportIndex: 2

  // Whether rowIndex (a row, or -1 for the search field) is the thing the
  // highlight should be following right now. Rows and the search field
  // both used to key their hasCursor off rowIndex alone, so stepping off
  // the top of the list into the player stack left rowIndex's old value
  // sitting there unchanged -- the search field (or a row) stayed lit at
  // the same time as whichever player stop the cursor actually moved to.
  // Every row/search hasCursor binding should use this, not root.cursorActive
  // directly, so only one thing is ever highlighted at a time.
  readonly property bool rowCursorVisible: cursorActive && playerIndex < 0

  // Which vertical stop index i is -- the only two things j/k ever land
  // on in the stack.
  function playerStopKind(i) {
    return (_playerSeekOffset === 1 && i === 0) ? "seek" : "transport"
  }

  // The CLI verb a transport position performs -- which doubles as its
  // identity, since "favorite" and "details" are not themselves plain command
  // arguments (favorite needs the current track's id and a direction, and
  // details never leaves the panel at all).
  function transportKind() {
    return ["favorite", "prev", "toggle", "next", "details"][transportIndex]
  }

  // j/k out of the top of the list reaches the search field, then the
  // player stack, landing on whichever stop is nearest -- the same "enter
  // a group from its near edge" rule the display widget uses for its
  // sections. j/k walk the stack from there; running off its top does
  // nothing further, and off its bottom returns to the search field, then
  // the list. Landing on the search field is a stop, not an edit: it picks
  // up the shared cursor highlight (searchField.hasCursor, bound below)
  // without taking keyboard focus, so j/k keep walking straight over it
  // the way they walk over any other row. Enter is what actually steps
  // into it -- see keyCatcher's onActivateRequested.
  function moveCursor(step) {
    if (!cursorActive) { cursorActive = true; return }
    if (playerIndex >= 0) {
      var next = playerIndex + step
      if (next < 0) return
      if (next >= playerStopCount) { playerIndex = -1; rowIndex = -1; return }
      playerIndex = next
      // Landing on the transport stop always re-centers on play/pause --
      // favorite/prev/next/expand are reached with h/l from there, not by
      // walking further with j/k.
      if (playerStopKind(playerIndex) === "transport") transportIndex = 2
      return
    }
    if (rowIndex < 0) {
      if (step > 0) rowIndex = 0
      else if (path.length === 0) { playerIndex = playerStopCount - 1; transportIndex = 2 }
      return
    }
    if (step < 0 && rowIndex === 0 && path.length === 0) {
      rowIndex = -1
      return
    }
    rowIndex += step
    clampCursor()
  }

  readonly property int seekStepSeconds: 10

  // A direct seek per keypress rather than a live-dragged preview: h/l is a
  // nudge, not a drag, and send() already collapses a run of quick presses
  // into just the last one.
  function seekBy(deltaSeconds) {
    if (!track) return
    var duration = playback.duration || 0
    var current = playback.elapsed || 0
    var next = Math.max(0, Math.min(duration, current + deltaSeconds))
    send(["seek", String(Math.round(next))])
  }

  // The heart already knows which way it is pointing -- the widget just
  // showed it -- so the direction goes over explicitly rather than asking the
  // CLI to fetch the current state and flip it, which would cost an extra
  // round trip on every press.
  function toggleFavorite() {
    if (!track) return
    send(["favorite", track.id, favorite ? "--off" : "--on"])
  }

  // h/l on the seek stop scrubs, same as h/l on the display widget's
  // brightness slider; on the transport stop they walk
  // favorite/prev/play/next/expand instead, the same as h/l on that widget's
  // scale-preset row -- and stay inside the transport rather than spilling
  // into the seek bar or the list, so the two meanings of the key never
  // fight over one press.
  function movePlayerCursorH(step) {
    if (playerStopKind(playerIndex) === "seek") { seekBy(step * seekStepSeconds); return }
    var next = transportIndex + step
    if (next < 0 || next > 4) return
    transportIndex = next
  }

  // What a track queues -- and it is never the one track on its own, but the
  // list it was found in, started at the song you picked. Artists, albums and
  // playlists do not come through here: they open, and the Play all row inside
  // them carries their command.
  function playCommand(row) {
    // A track found by searching has no list around it but the search itself.
    var source = row.source || ["--search", queryText.trim()]
    return ["play"].concat(source).concat(["--start", row.key])
  }

  // The command behind a level's Play all row, or null for a level that is not
  // a thing you play -- the queue, or the lists of everything.
  function levelPlayAll(entry) {
    if (!entry) return null
    if (entry.kind === "artist") return ["play", "--artist", entry.key]
    if (entry.kind === "album") return ["play", "--album", entry.key]
    if (entry.kind === "playlist") return ["play", "--playlist", entry.key]
    if (entry.kind === "favorites") return ["play", "--favorites"]
    return null
  }

  // One rule, no exceptions: a row with something inside it opens, and a row
  // that is the thing itself plays. The chevron says which you are looking at.
  //
  // Playing is what replaces the queue and the song you were on, with no way
  // back, so it is never what the whole width of a row does by accident.
  // Opening costs an Escape to undo. Every level you can open starts with a
  // Play all that says how much it is about to queue, so nothing is buried --
  // it is one more click than it was, spent on knowing what you are getting.
  function activateRow(row) {
    if (!row) return
    if (row.kind === "back") popLevel()
    else if (isOpenable(row)) openRow(row)
    else if (row.kind === "note") return
    else if (row.kind === "action") send(row.command)
    else if (row.kind === "queued") send(["jump", row.key])
    else send(playCommand(row))
  }

  function openRow(row) {
    if (!isOpenable(row)) return
    // A section is a level in its own right; anything else is a level named
    // after the thing you opened.
    pushLevel(row.kind === "section"
      ? { kind: row.key, key: "", label: row.label }
      : { kind: row.kind, key: row.key, label: row.label })
  }

  function pushLevel(entry) {
    if (path.length === 0 && searchMode) rootQuery = queryText.trim()
    clearSearch()
    path = path.concat([entry])
    // Onto the first row of the new level rather than the way back out.
    rowIndex = 1
    // Shown rather than left implicit: you have just navigated, so where the
    // cursor sits is the answer to what Enter is about to do -- and on an
    // artist what it is about to do is queue the lot.
    cursorActive = true
    loadLevel(entry)
  }

  function popLevel() {
    if (path.length === 0) return
    clearSearch()
    var remaining = path.slice(0, path.length - 1)
    path = remaining
    rows = []
    queueIndex = -1
    rowIndex = 0
    cursorActive = true
    if (remaining.length > 0) {
      loadLevel(remaining[remaining.length - 1])
    } else if (rootQuery !== "") {
      searchField.text = rootQuery
      rootQuery = ""
    }
    clampCursor()
  }

  function popToRoot() {
    if (path.length === 0) return
    clearSearch()
    path = []
    rows = []
    queueIndex = -1
    rowIndex = 0
    pendingLevel = null
    rootQuery = ""
  }

  // A command that arrived while another was still running. Two quick presses
  // on next used to lose the second one; now the last one in waits its turn,
  // which for a skip is the press you actually meant. Only the last is kept:
  // holding the key down should land you further along, not queue up a dozen
  // skips to sit through.
  property var queuedSend: null

  function send(args) {
    if (actionProc.running) { queuedSend = args; return }
    notice = ""
    actionProc.command = [cli].concat(args)
    actionProc.running = true
  }

  function loadLevel(entry) {
    loadingRows = true
    rows = []
    queueIndex = -1
    // Opening two levels quickly is one keypress after another, so the second
    // one waits rather than being dropped -- which is what the panel standing
    // empty on a level you just opened used to be.
    if (listProc.running) { pendingLevel = entry; return }
    pendingLevel = null
    listProc.level = entry
    listProc.command = [cli].concat(levelCommand(entry))
    listProc.running = true
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  // Searching as you type means one process per keystroke unless it is held
  // back, so the query waits for a short quiet. Only ever one search in
  // flight: a slow one that finished late would otherwise overwrite the
  // results of the query you have already moved on to.
  function runSearch() {
    // Inside a level the box filters what is already listed, and asking the
    // server for the same word would answer a question nobody asked.
    if (path.length > 0) return
    var query = queryText.trim()
    if (query.length < searchMinimum) {
      results = []
      resultsQuery = query
      return
    }
    if (searchProc.running) { searchDebounce.restart(); return }
    notice = ""
    searchProc.query = query
    searchProc.command = [cli, "search", query, "--json"]
    searchProc.running = true
  }

  function clearSearch() {
    searchDebounce.stop()
    searchField.text = ""
    results = []
    resultsQuery = ""
  }

  function refreshAccount() {
    if (!accountProc.running) accountProc.running = true
  }

  function logIn() {
    if (loginProc.running) return
    if (serverField.text.trim() === "" || userField.text.trim() === "") {
      notice = "Server and username are required."
      return
    }
    notice = ""
    loggingIn = true
    loginProc.secret = passwordField.text
    loginProc.command = [cli, "login", "--server", serverField.text.trim(),
                         "--user", userField.text.trim(), "--password-stdin", "--json"]
    loginProc.running = true
  }

  function cleanError(text) {
    return String(text || "").replace("omarchy-jellyfin: ", "").trim()
  }

  Process {
    id: statusProc
    running: false
    command: [root.cli, "status", "--json"]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      try {
        root.playback = JSON.parse(String(statusOut.text || "").trim())
      } catch (e) {
        // A malformed status is not worth surfacing; the next poll will do.
      }
    }
  }

  Process {
    id: accountProc
    running: false
    command: [root.cli, "server", "--json"]
    stdout: StdioCollector { id: accountOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      try {
        root.account = JSON.parse(String(accountOut.text || "").trim())
        if (root.account.server && serverField.text === "") serverField.text = root.account.server
      } catch (e) {
      }
    }
  }

  Process {
    id: loginProc
    running: false
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      // Anything that can read /proc sees argv, so the password goes here.
      write(secret + "\n")
      secret = ""
    }
    stderr: StdioCollector { id: loginErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.loggingIn = false
      passwordField.text = ""
      if (exitCode !== 0) {
        root.notice = root.cleanError(loginErr.text)
        return
      }
      root.notice = ""
      root.refreshAccount()
    }
  }

  Process {
    id: actionProc
    running: false
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.notice = root.cleanError(actionErr.text)
      // Playback state lags the command by a moment, so nudge the poll along.
      settleTimer.restart()
      // Logging out is the one action that changes who is signed in, and only
      // now has it actually happened -- asking while it was still running,
      // which the button used to, read the old config and left "Signed in
      // as ..." standing until the panel was reopened.
      if (actionProc.command.indexOf("logout") !== -1) root.refreshAccount()
      if (root.queuedSend) {
        var next = root.queuedSend
        root.queuedSend = null
        // Deferred rather than sent from inside the handler: this process is
        // only finished once the handler returns, and send() would take that
        // for another one still running and queue it right back.
        Qt.callLater(function() { root.send(next) })
      }
    }
  }

  Process {
    id: listProc
    running: false
    // The level this run answers, so a slow reply is never credited to the
    // one opened after it.
    property var level: null
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    stderr: StdioCollector { id: listErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.loadingRows = false
      if (root.pendingLevel) {
        var next = root.pendingLevel
        root.pendingLevel = null
        // Deferred rather than started from inside the handler: this process
        // counts as running until the handler returns, and loadLevel would
        // take that for a busy one and queue the level right back.
        Qt.callLater(function() { root.loadLevel(next) })
        return
      }
      if (!root.sameLevel(listProc.level, root.level)) return
      if (exitCode !== 0) {
        root.notice = root.cleanError(listErr.text)
        root.rows = []
        return
      }
      try {
        var data = JSON.parse(String(listOut.text || "").trim())
        // The queue reports which entry is current alongside the list; the
        // other listings are plain arrays.
        if (listProc.level.kind === "queue") {
          root.queueIndex = data && data.index !== undefined ? data.index : -1
          root.rows = (data && data.tracks) || []
        } else {
          root.rows = data || []
        }
      } catch (e) {
        root.rows = []
      }
      root.clampCursor()
    }
  }

  Process {
    id: searchProc
    running: false
    // The query this run answers, so a reply is never credited to the one
    // typed after it.
    property string query: ""
    stdout: StdioCollector { id: searchOut; waitForEnd: true }
    stderr: StdioCollector { id: searchErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.resultsQuery = searchProc.query
      if (exitCode !== 0) {
        root.notice = root.cleanError(searchErr.text)
        root.results = []
        return
      }
      try {
        root.results = JSON.parse(String(searchOut.text || "").trim()) || []
      } catch (e) {
        root.results = []
      }
      root.clampCursor()
    }
  }

  Timer {
    id: searchDebounce
    interval: 250
    repeat: false
    onTriggered: root.runSearch()
  }

  Timer {
    id: settleTimer
    interval: 350
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    // Every poll is a process spawn, and this timer runs for as long as the
    // session does, so the rate follows how much there is to learn. Open, the
    // seek bar wants a second. Closed with something playing, the bar only
    // needs a fresh title. Closed with nothing playing, nothing can change
    // except from a terminal -- and signed out, not even that. MPRIS drives
    // Omarchy's own media widget regardless.
    interval: root.opened ? 1000
      : (root.playback.running ? 5000 : (root.loggedIn ? 15000 : 60000))
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: refreshAccount()

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      // Lands on the seek bar first, the way the display widget lands on its
      // brightness slider -- not several sections down in the library.
      playerIndex = track !== null ? 0 : -1
      transportIndex = 2
      detailsExpanded = false
      refresh()
      refreshAccount()
    } else {
      path = []
      rows = []
      pendingLevel = null
      rootQuery = ""
      queueIndex = -1
      notice = ""
      passwordField.text = ""
      playerIndex = -1
      // Opening the panel again is usually a glance at what is playing, not a
      // return to the search you left behind.
      clearSearch()
    }
  }

  // Icon only, the way a bar-slot widget with nothing to label should be.
  // Built on WidgetButton rather than BarIconButton because that one is fixed
  // to a single icon slot and this still sizes itself off its own content.
  WidgetButton {
    id: button
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    dimmed: !root.playing
    tooltipText: root.tooltip
    // A vertical bar has no room for a label, so it falls back to icon-only.
    fixedWidth: root.barVertical ? -1 : barContent.implicitWidth + Style.space(12)
    fixedHeight: root.barVertical ? Style.bar.iconSlot : -1

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.send(["toggle"])
      else if (buttonCode === Qt.MiddleButton) root.send(["next"])
      else root.toggle()
    }

    Row {
      id: barContent
      anchors.centerIn: parent

      Text {
        id: barGlyph
        anchors.verticalCenter: parent.verticalCenter
        text: root.glyphMusic
        color: button.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // A text field owns the keyboard while it has focus, or typing a
      // password -- or a band name -- would trigger playback shortcuts.
      blocked: !root.loggedIn || searchField.activeFocus
      // Sideways walks the library the way the chevrons do: right opens what
      // the cursor is on, left steps back out of the level you are in -- or,
      // on a player stop, sideways moves the way h/l does on the display
      // widget: scrubbing on the seek bar, walking prev/play/next on a
      // transport button.
      onMoveRequested: function(dx, dy) {
        if (dx > 0) {
          // Same courtesy the first j or k gets: show the cursor where it
          // already is rather than acting on whatever it happened to rest on.
          if (!root.cursorActive) { root.cursorActive = true; return }
          if (root.playerIndex >= 0) root.movePlayerCursorH(1)
          else root.openRow(root.navRows[root.rowIndex])
        } else if (dx < 0) {
          if (root.playerIndex >= 0) {
            if (!root.cursorActive) { root.cursorActive = true; return }
            root.movePlayerCursorH(-1)
          } else {
            // Stepping back out of a level needs no reveal first: there is
            // nothing ambiguous about "go up", unlike opening a row.
            root.popLevel()
          }
        } else {
          root.moveCursor(dy)
        }
      }
      onActivateRequested: {
        if (!root.cursorActive) return
        if (root.playerIndex >= 0) {
          if (root.playerStopKind(root.playerIndex) === "seek") {
            root.send(["toggle"])
          } else {
            var tKind = root.transportKind()
            if (tKind === "details") root.detailsExpanded = !root.detailsExpanded
            else if (tKind === "favorite") root.toggleFavorite()
            else root.send([tKind])
          }
        } else if (root.rowIndex < 0) {
          // Enter is what actually steps onto the search field's own stop
          // rather than just walking over it -- j/k alone never focus it.
          searchField.forceActiveFocus()
        } else {
          root.activateRow(root.navRows[root.rowIndex])
        }
      }
      // A ladder out, so Escape never throws away more than you meant.
      onCloseRequested: if (root.path.length > 0) root.popLevel(); else root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === " ") root.send(["toggle"])
        else if (t === "n") root.send(["next"])
        else if (t === "p") root.send(["prev"])
        else if (t === "s") root.send(["play", "--shuffle", "--limit", String(root.setting("shuffleLimit", 200))])
        // "/" for search, the way a pager or a browser does it. Also
        // claims the row cursor from wherever it was (a player stop
        // included) so the field visibly lights up once focus lands.
        else if (t === "/") {
          root.cursorActive = true
          root.playerIndex = -1
          searchField.forceActiveFocus()
        }
      }

      // No Flickable here: the popup's own contentHeight is already capped
      // against screen space (panel.fittedContentHeight above), the way
      // network/Panel.qml's top-level Column is. The only scrolling region
      // is the browse-rows ListView below, so a long artist list scrolls in
      // place instead of dragging the search box and now-playing card off
      // screen with it.
      Column {
        id: column
        width: keyCatcher.width
        spacing: Style.space(8)

        // Connect. There is nothing else the panel can usefully do before
        // an account exists, so this is the whole of it -- no server
        // switching or log-out from here once signed in.
        Column {
          width: parent.width
          visible: !root.loggedIn
          spacing: Style.space(8)

          Text {
            width: parent.width
            text: "Connect to Jellyfin"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
          }

          TextField {
            id: serverField
            width: parent.width
            foreground: root.foreground
            placeholderText: "192.168.1.50:8096 or jellyfin.example.com"
            onAccepted: userField.forceActiveFocus()
          }

          TextField {
            id: userField
            width: parent.width
            foreground: root.foreground
            placeholderText: "Username"
            onAccepted: passwordField.forceActiveFocus()
          }

          TextField {
            id: passwordField
            width: parent.width
            foreground: root.foreground
            password: true
            placeholderText: "Password"
            onAccepted: root.logIn()
          }

          Button {
            text: root.loggingIn ? "Connecting…" : "Log in"
            enabled: !root.loggingIn
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.logIn()
          }
        }

        // Now playing: art on the left, title/artist/album/scrubber to its
        // right, transport below both -- spanning the full width, flush
        // with the art's left edge, rather than starting where the text
        // column does.
        Item {
          width: parent.width
          visible: root.loggedIn
          implicitHeight: Math.max(artFrame.height, infoColumn.height)
            + Style.space(seekBlock.visible ? 6 : 8) + transportBlock.implicitHeight

          Rectangle {
            id: artFrame
            anchors.left: parent.left
            anchors.top: parent.top
            visible: root.showArt && root.track !== null
            width: visible ? Style.space(80) : 0
            height: visible ? Style.space(80) : 0
            radius: Style.space(6)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
            clip: true

            Image {
              id: artImage
              anchors.fill: parent
              source: root.showArt && root.playback.art ? root.playback.art : ""
              sourceSize.width: 160
              sourceSize.height: 160
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              cache: true
              visible: status === Image.Ready
            }

            // A library without cover art should not leave a hole.
            Text {
              anchors.centerIn: parent
              visible: !artImage.visible
              text: root.glyphMusic
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }

          Item {
            id: infoColumn
            anchors.left: artFrame.visible ? artFrame.right : parent.left
            anchors.leftMargin: artFrame.visible ? Style.space(12) : 0
            anchors.right: parent.right
            anchors.top: parent.top
            implicitHeight: textStack.implicitHeight
              + (seekBlock.visible ? Style.space(8) + seekBlock.implicitHeight : 0)
            height: implicitHeight

            Column {
              id: textStack
              width: parent.width
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: root.track ? root.track.title : (root.loggedIn ? "Nothing playing" : "Connect a server to start")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                visible: root.track && root.track.artist !== ""
                text: root.track ? root.track.artist : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                visible: root.track && root.track.album !== ""
                text: root.track ? root.track.album : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            // Wrapped in the same cursor chrome the display widget's
            // brightness slider uses, so j/k reaching this row and h/l
            // seeking it look like the rest of the kit rather than a mouse
            // afterthought. Keyboard and mouse focus share this one
            // highlight, per CursorSurface's contract.
            Item {
              id: seekBlock
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: textStack.bottom
              anchors.topMargin: Style.space(8)
              visible: root.track !== null
              implicitHeight: seekSurface.height
              height: implicitHeight

              CursorSurface {
                id: seekSurface
                anchors.left: parent.left
                anchors.right: elapsedLabel.left
                anchors.rightMargin: Style.space(8)
                anchors.top: parent.top
                height: seekSlider.implicitHeight + Style.spacing.controlGap
                hasCursor: root.cursorActive && root.playerIndex === 0
                foreground: root.foreground
                outline: true

                PanelSlider {
                  id: seekSlider
                  bar: root.bar
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  minimum: 0
                  maximum: Math.max(1, root.playback.duration || 1)
                  step: 1
                  integer: true
                  value: root.playback.elapsed || 0
                  onReleased: function(position) { root.send(["seek", String(Math.round(position))]) }
                }

                HoverHandler {
                  onHoveredChanged: if (hovered) {
                    root.cursorActive = true
                    root.playerIndex = 0
                  }
                }
              }

              // Elapsed only, beside the scrubber -- how far into the
              // track you are is what matters glancing at a bar; the
              // duration is right there as how far the bar has left to go.
              Text {
                id: elapsedLabel
                anchors.right: parent.right
                anchors.verticalCenter: seekSurface.verticalCenter
                text: root.playback.elapsedText || "0:00"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // Transport, its own row spanning the full width below both the
          // art and the text column -- prev, play/pause, next, centered in
          // it the way they always were; favorite and the details toggle
          // flank them at the far left and far right, the same pairing the
          // display widget's own edge buttons use. All borderless and one
          // size, play/pause and a favorited track simply brighter as the
          // foreground action.
          Item {
            id: transportBlock
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: artFrame.height > infoColumn.height ? artFrame.bottom : infoColumn.bottom
            anchors.topMargin: Style.space(seekBlock.visible ? 6 : 8)
            implicitHeight: Math.max(transport.implicitHeight, detailsToggle.implicitHeight, favoriteToggle.implicitHeight)
            height: implicitHeight

            // Mirrors detailsToggle on the opposite edge: the one button on
            // this row that acts on the track rather than on the queue, so
            // it sits apart from prev/play/next rather than among them.
            Button {
              id: favoriteToggle
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.favorite ? root.glyphHeart : root.glyphHeartOutline
              foreground: root.favorite ? root.foreground : root.dim
              fontFamily: root.fontFamily
              iconSize: Style.font.icon
              hasCursor: root.cursorActive
                && root.playerIndex === root._playerSeekOffset
                && root.transportIndex === 0
              onClicked: root.toggleFavorite()
              onHovered: function(h) {
                if (h) {
                  root.cursorActive = true
                  root.playerIndex = root._playerSeekOffset
                  root.transportIndex = 0
                }
              }
            }

            Row {
              id: transport
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Repeater {
                model: [
                  { glyph: root.glyphPrev, action: "prev", primary: false },
                  { glyph: root.playing ? root.glyphPause : root.glyphPlay, action: "toggle", primary: true },
                  { glyph: root.glyphNext, action: "next", primary: false }
                ]

                Button {
                  required property var modelData
                  required property int index
                  iconText: modelData.glyph
                  foreground: modelData.primary ? root.foreground : root.dim
                  fontFamily: root.fontFamily
                  iconSize: Style.font.icon
                  // Offset by one: favorite sits outside this Repeater at
                  // transportIndex 0, so prev/toggle/next start at 1.
                  hasCursor: root.cursorActive
                    && root.playerIndex === root._playerSeekOffset
                    && root.transportIndex === index + 1
                  onClicked: root.send([modelData.action])
                  onHovered: function(h) {
                    if (h) {
                      root.cursorActive = true
                      root.playerIndex = root._playerSeekOffset
                      root.transportIndex = index + 1
                    }
                  }
                }
              }
            }

            // Folds away everything below the divider -- search and the
            // browse list -- so the panel can sit as a small now-playing
            // card. Same button as favorite/prev/play/next, just off to the
            // side rather than among them so those stay centered on the
            // card regardless -- and the far end of the same transport
            // stop, so h/l walks onto it exactly like the rest.
            Button {
              id: detailsToggle
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.detailsExpanded ? root.glyphCollapse : root.glyphExpand
              foreground: root.dim
              fontFamily: root.fontFamily
              iconSize: Style.font.icon
              hasCursor: root.cursorActive
                && root.playerIndex === root._playerSeekOffset
                && root.transportIndex === 4
              onClicked: root.detailsExpanded = !root.detailsExpanded
              onHovered: function(h) {
                if (h) {
                  root.cursorActive = true
                  root.playerIndex = root._playerSeekOffset
                  root.transportIndex = 4
                }
              }
            }
          }
        }

        Rectangle {
          width: parent.width
          visible: root.loggedIn && root.detailsExpanded
          height: Style.spacing.hairline
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
        }

        // Search. Above the quick picks because it is the way into a library
        // too large to ever be listed; the picks below are the shortcuts for
        // when you already know what you are in the mood for.
        Item {
          width: parent.width
          visible: root.loggedIn && root.detailsExpanded
          implicitHeight: searchField.implicitHeight

          TextField {
            id: searchField
            anchors.left: parent.left
            anchors.right: parent.right
            foreground: root.foreground
            // The panel-cursor resting here (root.rowIndex === -1) paints
            // the same hover-cursor chrome a hovered/keyboard-selected row
            // gets, without taking keyboard focus -- j/k can keep walking
            // straight over the field. Enter is what actually steps in.
            hasCursor: root.rowCursorVisible && root.rowIndex < 0
            // One box, two jobs, decided by where you are standing: at the
            // picks there is a library to search, and inside a level there
            // is a list in front of you to narrow.
            placeholderText: root.level
              ? "Filter " + root.level.label
              : "Search artists, albums and tracks"

            onTextChanged: {
              root.queryText = text
              // The cursor belongs on the top hit of the new query, not on
              // whatever row it happened to be resting on. Inside a level
              // row zero is the way back, so the first match is row one.
              root.rowIndex = root.path.length > 0 ? 1 : 0
              // Filtering needs no process and no waiting; searching does.
              if (root.path.length === 0) searchDebounce.restart()
            }

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                // A ladder out: the query first, then the level, then the
                // field, then the panel -- so Escape never throws away more
                // than you meant.
                if (searchField.text !== "") root.clearSearch()
                else if (root.path.length > 0) root.popLevel()
                else keyCatcher.forceActiveFocus()
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                root.moveCursor(1)
                event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                root.moveCursor(-1)
                event.accepted = true
              } else if (event.key === Qt.Key_Right
                         && searchField.cursorPosition === searchField.text.length) {
                // Only once the caret has nowhere left to go, where the key
                // would otherwise do nothing: that is what makes it free to
                // mean "open this" without ever costing you an edit. It is
                // the whole point of typing a band name -- right to see the
                // albums, Enter to just play them.
                root.openRow(root.navRows[root.rowIndex])
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                // Enter plays the top hit, so the common case is type and
                // go without ever leaving the field.
                root.activateRow(root.navRows[root.rowIndex])
                event.accepted = true
              }
            }
          }
        }

        // Quick picks, plus whichever section is folded open. A ListView
        // rather than a Column+Repeater so a long artist/album list scrolls
        // on its own, capped and clipped, instead of inflating column's
        // implicitHeight and dragging the search box and now-playing card
        // off screen with it -- the same shape network/Panel.qml's wifi
        // list and Ui/SearchableDropdown.qml use. currentIndex tracks
        // root.rowIndex so j/k navigation (via keyCatcher/moveCursor above)
        // scrolls the selected row into view instead of walking off the
        // visible window blind.
        ListView {
          width: parent.width
          visible: root.loggedIn && root.detailsExpanded
          height: Math.min(contentHeight, Style.space(280))
          // Same gap CursorSurface rows use in stappmus.activity-monitor's
          // process list -- the row itself carries the padding, so the
          // list only needs a hairline of separation, not a hairline that
          // is also expected to double as the padding.
          spacing: Style.spacing.xxs
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          model: root.navRows
          currentIndex: root.rowIndex
          onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

          // CursorSurface is the same background/border/hover chrome the
          // wifi network list and the process list build their rows on --
          // adopting it directly, instead of a hand-rolled highlight
          // Rectangle, is what makes these rows match.
          delegate: CursorSurface {
            id: navRow
            required property var modelData
            required property int index
            width: ListView.view.width
            implicitHeight: Style.spacing.controlHeight
            readonly property bool isCurrent: modelData.kind === "queued"
              && modelData.glyph !== ""
            readonly property bool opens: root.isOpenable(modelData)
            // Whether a row is a song, not a folder -- the only rows the
            // favorite heart applies to.
            readonly property bool isSong: modelData.kind === "track" || modelData.kind === "queued"

            foreground: root.foreground
            // Per CursorSurface's contract, hasCursor is the only thing
            // allowed to drive the highlight -- rowArea below folds mouse
            // hover into root.cursorActive/rowIndex rather than painting
            // its own, so keyboard and mouse can never show two different
            // rows highlighted at once.
            hasCursor: root.rowCursorVisible && root.rowIndex === index
            // The currently-queued track keeps its highlight even once the
            // cursor has moved off it, the way wifi keeps the connected
            // network lit.
            current: isCurrent

            Text {
              id: rowGlyph
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              // Queue rows keep the column even when empty, so titles line
              // up instead of stepping right for the one that is playing.
              visible: modelData.glyph !== "" || modelData.kind === "queued"
              width: modelData.kind === "queued" ? Style.space(11) : implicitWidth
              text: modelData.glyph
              color: isCurrent ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: modelData.kind === "queued" ? Style.font.caption : Style.font.body
            }

            Text {
              anchors.left: rowGlyph.visible ? rowGlyph.right : parent.left
              anchors.leftMargin: rowGlyph.visible ? Style.space(8) : Style.spacing.md
              anchors.right: chevron.visible ? chevron.left : (favoriteMark.visible ? favoriteMark.left : parent.right)
              anchors.rightMargin: chevron.visible || favoriteMark.visible ? Style.space(6) : Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              // Deliberately a block, not the one-line ternary this was.
              // As an optimised single-expression binding it gets
              // evaluated once before the delegate has injected
              // modelData, resolves to undefined, and logs "Unable to
              // assign [undefined] to QString" -- once per row per
              // rebuild, and the model rebuilds on every status poll. The
              // row rendered fine either way; the journal did not.
              text: {
                var label = modelData && modelData.label !== undefined ? modelData.label : ""
                var detail = modelData ? modelData.detail : ""
                return detail ? label + "  ·  " + detail : label
              }
              // In the queue only the track playing carries full weight;
              // the rest is context you scan past -- as is the trail back,
              // which says where you are rather than offering anything.
              color: modelData.kind === "note" || modelData.kind === "back" ? root.dim
                : (modelData.kind === "queued" && !isCurrent ? root.dim : root.foreground)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              // A trail too long for the panel loses its head rather than
              // its tail: where you are is the part worth keeping.
              elide: modelData.kind === "back" ? Text.ElideLeft : Text.ElideRight
            }

            // Whether a song is favorited, read-only here -- the transport
            // row above is where that gets changed, not the list. Filled for
            // one already favorited, outline otherwise, the same pairing the
            // transport's own favorite button uses.
            Text {
              id: favoriteMark
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              visible: navRow.isSong
              text: modelData.favorite === true ? root.glyphHeart : root.glyphHeartOutline
              color: modelData.favorite === true ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              id: chevron
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              // Above the row's own click area, so opening something and
              // playing it are two targets rather than one guess.
              z: 1
              visible: opens
              text: root.glyphOpen
              color: chevronArea.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall

              MouseArea {
                id: chevronArea
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                hoverEnabled: true
                enabled: opens
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.cursorActive = false
                  root.openRow(modelData)
                }
              }
            }

            MouseArea {
              id: rowArea
              anchors.fill: parent
              hoverEnabled: true
              enabled: modelData.kind !== "note"
              cursorShape: Qt.PointingHandCursor
              // Mouse entering claims the shared cursor the way wifi's row
              // does; leaving does not clear it, so the highlight stays
              // put and j/k pick up from here rather than from wherever
              // the keyboard cursor last was. playerIndex is reset too --
              // otherwise hovering a row while the cursor was parked on a
              // player stop would move rowIndex here but rowCursorVisible
              // would stay false, and nothing would visibly highlight.
              onContainsMouseChanged: if (containsMouse) {
                root.cursorActive = true
                root.playerIndex = -1
                root.rowIndex = index
              }
              onClicked: {
                root.cursorActive = false
                root.activateRow(modelData)
              }
            }
          }
        }

        // Errors from the CLI, which already phrases them for a human.
        Text {
          width: parent.width
          visible: root.notice !== "" && root.detailsExpanded
          text: root.notice
          color: bar ? bar.urgent : Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
