pragma ComponentBehavior: Bound

import QtQuick
import ".."

// Tx.qml — one Text for every M1 type role (m_base.css .lbl/.cap/.num/.fh).
// `role` picks face/size/tracking/caps; `tone` overrides the colour.
Text {
    id: root

    // num | cap | lbl | code | faint | micro | tag | hdr
    property string role: "cap"
    property color tone: role === "lbl" ? FuiTokens.dim
                       : role === "num" ? FuiTokens.white
                       : role === "code" ? FuiTokens.ice
                       : role === "faint" ? FuiTokens.faint
                       : role === "hdr" ? FuiTokens.white
                       : FuiTokens.mute

    color: tone
    elide: Text.ElideRight
    font.family: (role === "lbl" || role === "hdr")
                 ? FuiTokens.display : FuiTokens.mono
    font.pixelSize: role === "micro" ? FuiTokens.px.micro
                  : role === "tag" ? FuiTokens.px.tag : FuiTokens.px.body
    font.letterSpacing: role === "hdr" ? FuiTokens.ls.title
                      : role === "lbl" ? FuiTokens.ls.label
                      : role === "tag" ? FuiTokens.ls.tag
                      : FuiTokens.ls.cap
    font.capitalization: (role === "lbl" || role === "hdr")
                         ? Font.AllUppercase : Font.MixedCase
}
