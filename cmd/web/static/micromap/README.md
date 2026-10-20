# Vendored microMap

[microMap](https://github.com/Karte-Bayern/microMap) 0.3.0, pinned to commit
`57e41ae403c916415ff779d9c17a77ea68523bb2`. Licensed under [MIT](LICENSE).

`micromap.mjs` is the bundled ES module with no external runtime imports.
From the repository root:

- `make ensure-micromap-assets` verifies the bundle and licence offline.
- `make micromap-assets` rebuilds from the pinned source using Git, Node.js 22+
  and npm; network access is required.
