#!/usr/bin/env python3
"""Build a tiny Wikipedia-style .zim file for testing (needs `pip install libzim`).

The real Wikipedia files are 5-100 GB, so the Docker test uses this instead.
The pages copy the structure of real Kiwix Wikipedia pages (infobox, reference
markers, navigation boxes, "References" section) so the cleaning code is
exercised the same way.

Usage: make_test_zim.py OUTPUT.zim
"""

import sys

from libzim.writer import Creator, Hint, Item, StringProvider

ARTICLES = {
    "Capacitor": {
        "infobox": [("Type", "Passive"), ("Invented", "Ewald Georg von Kleist (1745)"), ("Electronic symbol", "two parallel lines")],
        "intro": [
            "A <b>capacitor</b> is a device that stores electrical energy by accumulating electric charges on two closely spaced surfaces that are insulated from each other.<sup class=\"reference\"><a href=\"#cite1\">[1]</a></sup> The capacitor was originally known as the condenser.",
            "It is a passive electronic component with two terminals. The effect of a capacitor is known as capacitance, which is measured in farads (F).<sup class=\"reference\">[2]</sup>",
        ],
        "sections": {
            "History": ["In October 1745, Ewald Georg von Kleist of Pomerania found that charge could be stored by connecting a generator to a volume of water in a hand-held glass jar. This became known as the Leyden jar."],
            "Theory of operation": [
                "A capacitor consists of two conductors separated by a non-conductive region called the dielectric. When a voltage is applied, an electric field develops across the dielectric, causing positive charge to collect on one plate and negative charge on the other.",
                "The energy stored in a capacitor is equal to one half of the capacitance multiplied by the square of the voltage.",
            ],
            "Applications": ["Capacitors are used in electronic circuits for blocking direct current while allowing alternating current to pass, in filter networks, for smoothing the output of power supplies, and in camera flashes."],
        },
    },
    "Resistor": {
        "infobox": [("Type", "Passive"), ("Working principle", "Electric resistance")],
        "intro": ["A <b>resistor</b> is a passive two-terminal electrical component that implements electrical resistance as a circuit element. Resistors are used to reduce current flow, adjust signal levels, and divide voltages."],
        "sections": {"Ohm's law": ["The behaviour of an ideal resistor is described by Ohm's law: the voltage across a resistor is proportional to the current through it."]},
    },
    "Inductor": {
        "infobox": [("Type", "Passive"), ("Inventor", "Michael Faraday")],
        "intro": ["An <b>inductor</b>, also called a coil, choke, or reactor, is a passive two-terminal electrical component that stores energy in a magnetic field when electric current flows through it."],
        "sections": {},
    },
    "Moon": {
        "infobox": [("Mean radius", "1,737.4 km"), ("Orbital period", "27.3 days"), ("Satellite of", "Earth")],
        "intro": ["The <b>Moon</b> is Earth's only natural satellite. It orbits at an average distance of 384,400 km, about 30 times the diameter of Earth.<sup class=\"reference\">[3]</sup> The Moon always presents the same side to Earth because of tidal locking."],
        "sections": {"Exploration": ["The first humans to land on the Moon were Neil Armstrong and Buzz Aldrin during the Apollo 11 mission on 20 July 1969."]},
    },
    "Apollo 11": {
        "infobox": [("Mission type", "Crewed lunar landing"), ("Launch date", "16 July 1969"), ("Crew", "Neil Armstrong, Buzz Aldrin, Michael Collins")],
        "intro": ["<b>Apollo 11</b> was the American spaceflight that first landed humans on the Moon. Commander Neil Armstrong and lunar module pilot Buzz Aldrin landed the Apollo Lunar Module Eagle on 20 July 1969. Armstrong became the first person to step onto the Moon's surface six hours later."],
        "sections": {},
    },
    "Neil Armstrong": {
        "infobox": [("Born", "5 August 1930, Wapakoneta, Ohio"), ("Died", "25 August 2012"), ("Occupation", "Astronaut, engineer")],
        "intro": ["<b>Neil Alden Armstrong</b> was an American astronaut and aeronautical engineer who in 1969 became the first person to walk on the Moon."],
        "sections": {},
    },
    "Photosynthesis": {
        "infobox": [],
        "intro": ["<b>Photosynthesis</b> is a system of biological processes by which photosynthetic organisms, such as most plants, algae and cyanobacteria, convert light energy, typically from sunlight, into the chemical energy necessary to fuel their metabolism. It produces oxygen as a by-product."],
        "sections": {"Overview": ["Most photosynthetic organisms use carbon dioxide and water, releasing oxygen. The process takes place in chloroplasts using the green pigment chlorophyll."]},
    },
    "Linux": {
        "infobox": [("Developer", "Community, Linus Torvalds"), ("Initial release", "17 September 1991"), ("Kernel type", "Monolithic")],
        "intro": ["<b>Linux</b> is a family of open-source Unix-like operating systems based on the Linux kernel, first released on 17 September 1991 by Linus Torvalds. Popular Linux distributions include Debian, Fedora Linux, Linux Mint and Ubuntu."],
        "sections": {},
    },
    "Linux Mint": {
        "infobox": [("Developer", "Linux Mint Team"), ("Based on", "Ubuntu"), ("Default desktop", "Cinnamon")],
        "intro": ["<b>Linux Mint</b> is a community-driven Linux distribution based on Ubuntu, bundled with a variety of free and open-source applications. Its default desktop environment is Cinnamon."],
        "sections": {},
    },
    "Water": {
        "infobox": [("Formula", "H2O"), ("Boiling point", "100 °C"), ("Melting point", "0 °C")],
        "intro": ["<b>Water</b> is an inorganic compound with the chemical formula H<sub>2</sub>O. It is a transparent, tasteless, odorless, and nearly colorless chemical substance. It is the main constituent of Earth's hydrosphere and the fluids of all known living organisms."],
        "sections": {},
    },
    "Mercury (planet)": {
        "infobox": [("Orbital period", "88 days"), ("Mean radius", "2,439.7 km")],
        "intro": ["<b>Mercury</b> is the first planet from the Sun and the smallest in the Solar System. It is a rocky planet with a trace atmosphere."],
        "sections": {},
    },
    "Mercury (element)": {
        "infobox": [("Symbol", "Hg"), ("Atomic number", "80")],
        "intro": ["<b>Mercury</b> is a chemical element with the symbol Hg and atomic number 80. It is the only metal that is liquid at standard temperature and pressure."],
        "sections": {},
    },
    "Mercury": {
        "infobox": [],
        "intro": ["<b>Mercury</b> commonly refers to:", "Mercury may refer to:"],
        "list": ["Mercury (planet), the planet closest to the Sun", "Mercury (element), a chemical element"],
        "sections": {},
    },
}

PAGE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>{title}</title>
<link rel="stylesheet" href="../-/s/style.css"><script src="../-/j/script.js"></script></head>
<body class="mw-body mw-body-content">
<div id="content"><h1 class="section-heading">{title}</h1>
<div class="mw-parser-output">
<div role="note" class="hatnote navigation-not-searchable">For other uses, see {title} (disambiguation).</div>
{infobox}
{intro}
{listhtml}
{sections}
<h2>References</h2>
<div class="reflist"><ol class="references"><li id="cite1">Some book, page 12.</li></ol></div>
<table class="navbox"><tr><td>Electronics navigation box: Capacitor · Resistor · Inductor</td></tr></table>
</div></div></body></html>
"""


def render(title, data):
    infobox = ""
    if data["infobox"]:
        rows = "".join(f'<tr><th scope="row" class="infobox-label">{k}</th><td class="infobox-data">{v}</td></tr>' for k, v in data["infobox"])
        infobox = f'<table class="infobox"><caption class="infobox-title">{title}</caption>{rows}</table>'
    intro = "\n".join(f"<p>{p}</p>" for p in data["intro"])
    listhtml = ""
    if data.get("list"):
        listhtml = "<ul>" + "".join(f"<li>{x}</li>" for x in data["list"]) + "</ul>"
    sections = ""
    for head, paras in data["sections"].items():
        sections += f'<h2><span class="mw-headline">{head}</span><span class="mw-editsection">[edit]</span></h2>'
        sections += "".join(f"<p>{p}</p>" for p in paras)
        sections += '<table class="wikitable"><tr><td>Junk table cell</td></tr></table>'
    return PAGE.format(title=title, infobox=infobox, intro=intro, listhtml=listhtml, sections=sections)


class Page(Item):
    def __init__(self, path, title, content, mimetype="text/html", front=True):
        super().__init__()
        self.path, self.title, self.content, self.mimetype, self.front = path, title, content, mimetype, front

    def get_path(self):
        return self.path

    def get_title(self):
        return self.title

    def get_mimetype(self):
        return self.mimetype

    def get_contentprovider(self):
        return StringProvider(self.content)

    def get_hints(self):
        return {Hint.FRONT_ARTICLE: self.front}


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "wikipedia_en_test.zim"
    with Creator(out).config_indexing(True, "eng") as creator:
        creator.set_mainpath("Main_Page")
        for key, value in {
            "Name": "wikipedia_en_test",
            "Title": "Wikipedia (test)",
            "Description": "Tiny Wikipedia-style test file for cyberdeck",
            "Language": "eng",
            "Creator": "Wikipedia",
            "Publisher": "cyberdeck tests",
            "Date": "2026-10-01",
            "Flavour": "mini",
        }.items():
            creator.add_metadata(key, value)
        links = "".join(f'<li><a href="{t.replace(" ", "_")}">{t}</a></li>' for t in ARTICLES)
        creator.add_item(Page("Main_Page", "Main Page", f"<html><head><title>Main Page</title></head><body><h1>Test Wikipedia</h1><ul>{links}</ul></body></html>"))
        for title, data in ARTICLES.items():
            creator.add_item(Page(title.replace(" ", "_"), title, render(title, data)))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
