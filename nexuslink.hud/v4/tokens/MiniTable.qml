pragma ComponentBehavior: Bound

import QtQuick
import ".."

// MiniTable.qml — hairline data table (m_base.css .tb/.tb.grid).
// columns: [{key, label, align:"l"|"r", w:px | flex:n, role:"num"|"cap"|"dim"|"faint"|"code"}]
// rows:    list of objects; cell = row[col.key]. A cell may be a plain
//          value or {v: text, c: color, r: roleOverride}.
Item {
    id: root

    property var columns: []
    property var rows: []
    property int rowH: 15
    property bool header: true
    property bool grid: false          // hairline under every row
    property bool total: false         // last row gets a top rule + white tone
    property int padX: 4

    implicitWidth: 240
    implicitHeight: col.height

    function colW(i) {
        var c = columns[i];
        if (!c) return 0;
        if (c.w !== undefined) return c.w;
        var fixed = 0, flexN = 0;
        for (var k = 0; k < columns.length; k++) {
            var cc = columns[k];
            if (cc.w !== undefined) fixed += cc.w;
            else flexN += (cc.flex !== undefined ? cc.flex : 1);
        }
        return flexN > 0 ? Math.max(10, (width - fixed) * (c.flex !== undefined ? c.flex : 1) / flexN)
                         : Math.max(10, (width - fixed) / Math.max(1, columns.length));
    }

    Column {
        id: col
        anchors { left: parent.left; right: parent.right }

        Item {
            visible: root.header
            width: parent.width
            height: visible ? root.rowH + 4 : 0
            Row {
                anchors.fill: parent
                Repeater {
                    model: root.columns
                    delegate: Tx {
                        required property int index
                        required property var modelData
                        width: root.colW(index) - root.padX
                        height: root.rowH + 4
                        verticalAlignment: Text.AlignBottom
                        bottomPadding: 4
                        role: "code"
                        text: String(modelData.label || "")
                        horizontalAlignment: modelData.align === "r" ? Text.AlignRight : Text.AlignLeft
                        leftPadding: modelData.align === "r" ? 0 : root.padX
                        rightPadding: modelData.align === "r" ? root.padX : 0
                    }
                }
            }
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 1
                color: FuiTokens.hair2
            }
        }

        Repeater {
            model: root.rows
            delegate: Item {
                id: rowIt
                required property int index
                required property var modelData
                width: col.width
                height: root.rowH
                readonly property bool isTotal: root.total && index === root.rows.length - 1

                Row {
                    anchors.fill: parent
                    Repeater {
                        model: root.columns
                        delegate: Tx {
                            id: cell
                            required property int index
                            required property var modelData
                            readonly property var spec: root.columns[index] || {}
                            readonly property var v: rowIt.modelData[spec.key]
                            width: root.colW(index)
                            height: root.rowH
                            verticalAlignment: Text.AlignVCenter
                            role: (v !== null && typeof v === "object" && v.r !== undefined)
                                  ? v.r : (spec.role || "num")
                            text: {
                                if (v === null || v === undefined) return "";
                                if (typeof v === "object") return String(v.v !== undefined ? v.v : "");
                                return String(v);
                            }
                            tone: {
                                if (rowIt.isTotal && role === "num") return FuiTokens.white;
                                if (v !== null && typeof v === "object" && v.c !== undefined) return v.c;
                                switch (role) {
                                case "num": return FuiTokens.white;
                                case "code": return FuiTokens.ice;
                                case "dim": return FuiTokens.dim;
                                case "faint": return FuiTokens.faint;
                                default: return FuiTokens.mute;
                                }
                            }
                            horizontalAlignment: spec.align === "r" ? Text.AlignRight : Text.AlignLeft
                            leftPadding: spec.align === "r" ? 0 : root.padX
                            rightPadding: spec.align === "r" ? root.padX : 0
                        }
                    }
                }
                Rectangle {
                    visible: root.grid && !rowIt.isTotal
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 1
                    color: FuiTokens.hair3
                }
                Rectangle {
                    visible: rowIt.isTotal
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    height: 1
                    color: FuiTokens.hair2
                }
            }
        }
    }
}
