import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar icon for pending pacman + AUR updates. Left click opens a popup that
// lists them, with "Update now" (omarchy-update in a floating terminal) and
// "Remind me in N min/hours/days". Right click toggles the count.
//
// Backend (bundled): bin/update-list (the listing) and
// bin/update-check-notify (the toast; optionally run daily via
// extras/systemd). The snooze is an epoch
// in ~/.local/state/update-check/snooze-until, which the daily toast also
// honors; when it passes, this widget re-runs the toast with --force.
// Replaces the built-in omarchy.system-update widget (the omarchy package
// shows up in the System list, pinned to the top).
Panel {
  id: root
  moduleName: "jessica.updates"
  ipcTarget: "jessica.updates"
  manageIpc: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string listCmd: pluginDir + "/bin/update-list"
  readonly property string notifyCmd: pluginDir + "/bin/update-check-notify"
  readonly property string snoozeFile: home + "/.local/state/update-check/snooze-until"
  readonly property string updateCmd: "omarchy-launch-floating-terminal-with-presentation omarchy-update"

  property var repoUpdates: []
  property var aurUpdates: []
  property bool checking: false
  property bool checkedOnce: false
  property string error: ""
  property real lastChecked: 0
  property real snoozeUntil: 0      // ms epoch, 0 = not snoozed
  property real now: Date.now()

  // Set after "Update now": watch the omarchy-update lock and re-check once
  // the update releases it.
  property bool watchingUpdate: false
  property bool sawUpdateLock: false
  property real watchStarted: 0

  readonly property int total: repoUpdates.length + aurUpdates.length
  readonly property bool snoozed: snoozeUntil > now
  readonly property bool showCount: setting("showCount", true) === true
  readonly property int snoozeAmount: Math.max(1, Number(setting("snoozeAmount", 2)) || 2)
  readonly property string snoozeUnit: String(setting("snoozeUnit", "hours"))
  readonly property real openPanelIndicatorWidth: showCount && !button.vertical ? button.glyphPaintedWidth : 0

  // ---------- data ----------

  function refresh() {
    if (listProc.running) return
    root.checking = true
    listProc.running = true
  }

  function parseList(raw) {
    var repo = [], aur = [], err = ""
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var f = lines[i].split("\t")
      if (f[0] === "error") { err = f[1] || "Update check failed"; continue }
      if (f.length < 4) continue
      var item = { name: f[1], from: f[2], to: f[3], core: /^omarchy(-dev)?$/.test(f[1]) }
      if (f[0] === "aur") aur.push(item)
      else if (f[0] === "repo") repo.push(item)
    }
    repo.sort(function(a, b) { return (b.core ? 1 : 0) - (a.core ? 1 : 0) })
    root.checking = false
    root.checkedOnce = true
    root.error = err
    // Keep the last good list when a check fails (e.g. briefly offline).
    if (err !== "") return
    root.repoUpdates = repo
    root.aurUpdates = aur
    root.lastChecked = Date.now()
  }

  function saveSettings(patch) {
    root.settings = Object.assign({}, root.settings, patch)
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  // ---------- actions ----------

  function runUpdate() {
    if (root.bar) root.bar.run(root.updateCmd)
    setSnooze(0)
    close()
    root.sawUpdateLock = false
    root.watchStarted = Date.now()
    root.watchingUpdate = true
  }

  function unitMs(unit) {
    if (unit === "min") return 60 * 1000
    if (unit === "days") return 24 * 3600 * 1000
    return 3600 * 1000
  }

  function snoozeFor(amount, unit) {
    if (amount !== root.snoozeAmount) saveSettings({ snoozeAmount: amount })
    setSnooze(Date.now() + amount * unitMs(unit))
    close()
  }

  function setSnooze(ms) {
    root.snoozeUntil = ms
    snoozeWriteProc.command = ["bash", "-c",
      'mkdir -p "$(dirname "$1")"; if [ "$2" = 0 ]; then rm -f "$1"; else echo "$2" > "$1"; fi',
      "_", root.snoozeFile, String(Math.round(ms / 1000))]
    snoozeWriteProc.running = true
  }

  function checkSnooze() {
    root.now = Date.now()
    if (root.snoozeUntil > 0 && root.now >= root.snoozeUntil) {
      setSnooze(0)
      if (!notifyProc.running) notifyProc.running = true
      refresh()
    }
  }

  function toggleCount() { saveSettings({ showCount: !root.showCount }) }

  // ---------- formatting ----------

  function timeLabel(ms) {
    var d = new Date(ms), today = new Date()
    var sameDay = d.toDateString() === today.toDateString()
    var tomorrow = new Date(today.getTime() + 86400000).toDateString() === d.toDateString()
    var t = Qt.formatTime(d, "h:mm AP")
    if (sameDay) return t
    if (tomorrow) return "tomorrow " + t
    return Qt.formatDateTime(d, "ddd MMM d, h:mm AP")
  }

  readonly property string statusText: {
    if (checking && !checkedOnce) return "Checking…"
    if (error !== "") return error
    if (total === 0) return "Up to date"
    var s = total + (total === 1 ? " update" : " updates")
    if (lastChecked > 0) s += " · checked " + timeLabel(lastChecked)
    return s
  }

  readonly property string tooltip: {
    if (total === 0) return "No pending updates"
    var parts = []
    if (repoUpdates.length) parts.push(repoUpdates.length + " system")
    if (aurUpdates.length) parts.push(aurUpdates.length + " AUR")
    var s = total + (total === 1 ? " update" : " updates") + " (" + parts.join(", ") + ")"
    if (snoozed) s += "\nReminder at " + timeLabel(snoozeUntil)
    return s
  }

  // ---------- plumbing ----------

  IpcHandler {
    target: "jessica.updates"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  onOpenedChanged: {
    if (!opened) return
    root.now = Date.now()
    if (Date.now() - root.lastChecked > 10 * 60 * 1000) refresh()
  }

  visible: total > 0 || opened
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  Process {
    id: listProc
    command: [root.listCmd]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseList(text) }
    onExited: function(exitCode) { if (root.checking) root.checking = false }
  }

  Process {
    id: snoozeReadProc
    command: ["cat", root.snoozeFile]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var secs = parseInt(String(text || "").trim())
        root.snoozeUntil = isFinite(secs) && secs > 0 ? secs * 1000 : 0
        root.checkSnooze()
      }
    }
  }

  Process { id: snoozeWriteProc }
  Process { id: notifyProc; command: [root.notifyCmd, "--force"] }

  // Exit 0 while an omarchy-update holds its lock.
  Process {
    id: lockProc
    command: ["bash", "-c", 'l="${XDG_RUNTIME_DIR:-/tmp}/omarchy-update.lock"; [ -f "$l" ] && ! flock -n "$l" true']
    onExited: function(exitCode) {
      if (exitCode === 0) { root.sawUpdateLock = true; return }
      // Not (or no longer) running. Give the terminal a couple of minutes to
      // reach the lock before deciding the update was never started.
      if (root.sawUpdateLock || Date.now() - root.watchStarted > 180000) {
        root.watchingUpdate = false
        root.refresh()
      }
    }
  }

  Component.onCompleted: snoozeReadProc.running = true

  // First check shortly after login (network may not be up yet), then hourly.
  Timer { interval: 20000; running: true; repeat: false; onTriggered: root.refresh() }
  Timer { interval: 3600000; running: true; repeat: true; onTriggered: root.refresh() }
  // Retry sooner after a failed check.
  Timer { interval: 300000; running: root.error !== ""; repeat: true; onTriggered: root.refresh() }
  Timer { interval: 30000; running: root.snoozeUntil > 0 || root.opened; repeat: true; onTriggered: root.checkSnooze() }
  Timer {
    interval: 5000
    running: root.watchingUpdate
    repeat: true
    onTriggered: if (!lockProc.running) lockProc.running = true
  }

  // ---------- bar button ----------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showCount && !vertical ? " " + root.total : ""
    // Fit the slot to the painted "icon + count" with the same side padding a
    // plain icon gets (iconSlot - iconCanvas), so it spaces like its neighbors.
    slotSize: root.showCount && !vertical
      ? Math.max(Style.bar.iconSlot, Math.ceil(glyphPaintedWidth) + Style.bar.iconSlot - Style.bar.iconCanvas)
      : Style.bar.iconSlot
    fontSize: Style.font.caption
    opacity: root.snoozed && !root.opened ? 0.45 : 1
    tooltipText: root.opened ? "" : root.tooltip
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleCount()
      else root.toggle()
    }
  }

  // ---------- popup ----------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: amountField.field.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: if (root.total > 0) root.runUpdate()
      onTextKey: function(t) { if (t === "r") root.refresh() }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, refreshButton.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: ""
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: refreshButton.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Updates"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.statusText.toUpperCase()
              color: root.error !== "" ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Button {
            id: refreshButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: ""
            iconSpinning: root.checking
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            tooltipText: "Check again (r)"
            onClicked: root.refresh()
          }
        }

        // ---------- Package list ----------
        Flickable {
          id: listFlick
          visible: root.total > 0
          width: parent.width
          height: Math.min(listColumn.implicitHeight, Style.space(280))
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: listColumn
            width: listFlick.width
            spacing: Style.space(10)

            Repeater {
              model: [
                { title: "SYSTEM", items: root.repoUpdates },
                { title: "AUR", items: root.aurUpdates }
              ]

              Column {
                required property var modelData
                visible: modelData.items.length > 0
                width: listColumn.width
                spacing: Style.space(4)

                PanelSectionHeader {
                  text: modelData.title + " · " + modelData.items.length
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                }

                Repeater {
                  model: modelData.items

                  Item {
                    required property var modelData
                    width: listColumn.width
                    implicitHeight: Math.max(pkgName.implicitHeight, pkgVer.implicitHeight)

                    Text {
                      id: pkgName
                      textFormat: Text.PlainText
                      text: modelData.name
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: modelData.core
                      elide: Text.ElideRight
                      anchors.left: parent.left
                      width: Math.min(implicitWidth, parent.width * 0.5)
                    }

                    Text {
                      id: pkgVer
                      textFormat: Text.PlainText
                      text: modelData.from + "  →  " + modelData.to
                      color: root.bar.foreground
                      opacity: 0.6
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      horizontalAlignment: Text.AlignRight
                      elide: Text.ElideLeft
                      anchors.right: parent.right
                      width: parent.width - pkgName.width - Style.space(12)
                    }
                  }
                }
              }
            }
          }
        }

        Button {
          visible: root.total > 0
          width: parent.width
          iconText: ""
          text: "Update now"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          bordered: true
          active: true
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          onClicked: root.runUpdate()
        }

        // ---------- Remind me later ----------
        PanelSeparator {
          visible: root.total > 0
          foreground: root.bar.foreground
        }

        Column {
          visible: root.total > 0
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "REMIND ME LATER"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Item {
            visible: root.snoozed
            width: parent.width
            implicitHeight: Math.max(snoozeLabel.implicitHeight, cancelSnooze.implicitHeight)

            Text {
              id: snoozeLabel
              textFormat: Text.PlainText
              text: "Reminder set for " + root.timeLabel(root.snoozeUntil)
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              anchors.left: parent.left
              anchors.right: cancelSnooze.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
            }

            Button {
              id: cancelSnooze
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Cancel"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.setSnooze(0)
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            NumberField {
              id: amountField
              anchors.verticalCenter: parent.verticalCenter
              value: root.snoozeAmount
              from: 1
              to: 999
              fieldWidth: Style.space(72)
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onModified: function(v) { root.saveSettings({ snoozeAmount: v }) }
              // The typed text isn't committed to field.value until focus leaves.
              function current() {
                var n = parseInt(amountField.field.contentItem.text)
                return isFinite(n) && n > 0 ? n : amountField.field.value
              }

              Connections {
                target: amountField.field.contentItem
                function onAccepted() { root.snoozeFor(amountField.current(), root.snoozeUnit) }
              }
            }

            ButtonGroup {
              anchors.verticalCenter: parent.verticalCenter
              options: [
                { value: "min", label: "min" },
                { value: "hours", label: "hours" },
                { value: "days", label: "days" }
              ]
              value: root.snoozeUnit
              focusable: false
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onChanged: function(v) { root.saveSettings({ snoozeUnit: v }) }
            }

            Button {
              anchors.verticalCenter: parent.verticalCenter
              iconText: ""
              text: root.snoozed ? "Change" : "Remind me"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.snoozeFor(amountField.current(), root.snoozeUnit)
            }
          }
        }
      }
    }
  }
}
