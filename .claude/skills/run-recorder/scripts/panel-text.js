function run() {
    const process = Application("System Events").processes.byName("Recorder");
    if (process.windows.length === 0) return "no panel window";
    const lines = [];
    const controls = ["AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton"];
    function attempt(read) { try { const value = read(); return value === null || value === undefined ? "" : String(value); } catch (e) { return ""; } }
    function walk(element, depth) {
        if (depth > 25) return;
        const role = attempt(() => element.role());
        if (!role) return;
        if (role === "AXStaticText") {
            const value = attempt(() => element.value());
            if (value) lines.push(value);
        } else if (controls.includes(role)) {
            const name = attempt(() => element.name()) || attempt(() => element.title()) || attempt(() => element.help()) || attempt(() => element.description());
            const value = attempt(() => element.value());
            lines.push(`[${role.slice(2)}] ${name}${value ? " = " + value : ""}`);
        }
        const children = attempt(() => element.uiElements().length) ? element.uiElements() : [];
        for (let i = 0; i < children.length; i++) walk(children[i], depth + 1);
    }
    walk(process.windows[0], 0);
    return lines.join("\n");
}
