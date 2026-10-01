// Loaded from the plugin's own ui/ (script-src 'self'): when it runs, the
// page says so, and every button below is wired.
const out = document.getElementById("out");
const csp = document.getElementById("csp");
document.getElementById("js").textContent = "app.js ran";
const say = (label, v) => { out.textContent = label + ":\n" + (typeof v === "string" ? v : JSON.stringify(v, null, 2)); };
// What the page's own policy stopped, as the engine reports it. A fetch the
// policy blocks never leaves the page, so this is the only trace of it.
document.addEventListener("securitypolicyviolation", (e) => {
  csp.textContent = "blocked by the page's policy: " + e.violatedDirective + " -> " + e.blockedURI + "\n" + csp.textContent;
});
const has = typeof window.polter === "object" && window.polter !== null;
say("bridge present", has);
const guard = (label, p) => p.then(v => say(label + " OK", v), e => say(label + " FAILED", String(e)));
document.getElementById("read").onclick = () => guard("settings()", window.polter.settings());
document.getElementById("save").onclick = () => guard("save()", window.polter.save({ params: { label: "from-page" } }));
document.getElementById("net").onclick = () => guard("fetch example.com", fetch("https://example.com").then(r => "status " + r.status));
document.getElementById("up").onclick = () => guard("fetch ../plugin.json", fetch("../plugin.json").then(r => "status " + r.status));
document.getElementById("other").onclick = () => guard("fetch other plugin", fetch("polter-plugin://flaky/index.html").then(r => "status " + r.status));
document.getElementById("win").onclick = () => { const w = window.open("https://example.com"); say("window.open returned", String(w)); };
document.getElementById("close").onclick = () => guard("close()", window.polter.close());
