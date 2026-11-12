var window = globalThis; var self = globalThis;
load(arguments[0]);
var src = readFile(arguments[1]);
try {
  var r = pele.render(src, { links: false, images: false, idPrefix: "d1-" });
  print("OK type=" + r.type + " mermaidType=" + r.mermaidType + " keys=" + Object.keys(r).join(","));
  print(r.svg);
} catch (e) { print("ERROR " + e); }
