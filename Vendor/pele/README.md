# Pele (vendored)

[Pele](https://github.com/obsidianmd/pele) renders Mermaid diagram source to SVG. Maser runs it in JavaScriptCore,
outside any web page, to draw the review agent's diagrams (REQ-CNV-002). MIT licensed; see `LICENSE`.

| | |
| --- | --- |
| Version | 1.12.0 (published 2026-10-26) |
| File | `pele.global.js`, from the npm package's `dist/` |
| npm integrity | `sha512-3OdOK6rvkaTB569R4/I8U0H82MqPRxj7vfkbowa2rRhgSBPFhvWlfFy5eae0jP+2A6hE8abE17nsdyxJz2VBiQ==` |
| SHA-256 of the file | `787ed66bb4bd56c15e224109ff5b89ed395ebfacf71fae2c0ccad1f86d6e24ef` |

It's copied into the repository, not fetched at build or run time, and `DiagramRendererTests.vendoredPele` checks the
file's SHA-256, so a change to it can't go unnoticed.

To update: pick a release at least two weeks old (`npm view pele time`), `npm pack pele@<version>` into an empty
folder, check the tarball against `npm view pele@<version> dist.integrity`, copy `dist/pele.global.js` and `LICENSE`
here, and update this table, the test's hash, and the SOUP row in `docs/design/software-development-plan.md`.
