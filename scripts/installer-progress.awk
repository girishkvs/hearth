function clean(text) {
    gsub(/[^ -~]/, "", text)
    sub(/\.\.\.$/, "", text)
    sub(/^ +/, "", text)
    sub(/ +$/, "", text)
    return text
}

function remember(text, i) {
    if (text == "" || text == lastDiagnostic) return
    lastDiagnostic = text
    for (i = 1; i < 8; i++) history[i] = history[i + 1]
    history[8] = text
    if (diagnostics != "") {
        printf "%s", "" > diagnostics
        for (i = 1; i <= 8; i++)
            if (history[i] != "") print history[i] > diagnostics
        close(diagnostics)
    }
}

function render(    line, bar, filled, i, label) {
    if (interactive) {
        filled = known ? int(percent * width / 100) : 0
        bar = ""
        for (i = 0; i < width; i++) bar = bar (i < filled ? "#" : "-")
        label = known ? sprintf("%2d%%", percent) : "--%"
        line = "[" bar "] " label "  " phase
        if (length(line) >= columns) line = substr(line, 1, columns - 4) "..."
        if (line != lastLine) {
            printf "\r%s%*s", line, (length(lastLine) > length(line) ? length(lastLine) - length(line) : 0), ""
            fflush()
            lastLine = line
        }
    } else if (phase != lastPhase) {
        print phase
        fflush()
    }
    lastPhase = phase
}

BEGIN {
    if (columns !~ /^[0-9]+$/ || columns < 30) columns = 80
    width = columns < 60 ? 10 : 20
    phase = "Waiting for Installer progress"
}

{
    text = clean($0)
    if (tolower(text) ~ /(error|failed|failure|cancelled|canceled|refused)/) remember(text)
    if (text ~ /^installer:PHASE:/) {
        sub(/^installer:PHASE:/, "", text)
        text = clean(text)
        if (finishing || tolower(text) ~ /(successfully installed|install was successful)/) next
        if (text != "") phase = text
        render()
    } else if (text ~ /^installer:%/) {
        sub(/^installer:%/, "", text)
        if (text !~ /^[0-9]+([.][0-9]+)?$/ || text + 0 > 100) next
        # Completion is reported only after the native process exits successfully.
        if (int(text + 0.5) >= 100) {
            finishing = 1
            next
        }
        known = 1
        percent = int(text + 0.5)
        render()
    } else if (text !~ /^installer:STATUS:/ &&
               text !~ /^installer: (Package name is |Installing at base path |The install was successful)/) {
        remember(text)
    }
}
