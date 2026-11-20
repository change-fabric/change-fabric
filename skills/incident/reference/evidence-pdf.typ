// Evidence PDF for a client incident report. incident_report.rb copies this
// next to evidence.json (title, footer, shots) and the screenshots, then
// compiles it. One page per route and viewport; the footer states what was
// captured.
#let data = json("evidence.json")

#set document(title: data.title)
#set text(size: 10pt)
#set page(
  paper: "a4",
  margin: (x: 1.6cm, top: 1.6cm, bottom: 2cm),
  footer: context [
    #set text(size: 8pt, fill: luma(90))
    #data.footer
    #h(1fr)
    #counter(page).display() / #counter(page).final().first()
  ],
)

#for (i, shot) in data.shots.enumerate() [
  #if i > 0 [#pagebreak()]
  #text(size: 13pt, weight: "bold")[#shot.caption]
  #v(0.4cm)
  #align(center, image(shot.file, width: 100%, height: 22cm, fit: "contain"))
]
