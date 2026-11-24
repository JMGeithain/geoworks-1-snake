# Schnecke – Snake für GeoWorks 1

Kleines Snake-Spiel für GeoWorks 1 (getestet mit GeoWorks 1.28 / Ensemble 1.2), geschrieben in 8086-Assembler mit dem [pcgeos-1-sdk-v2](https://github.com/dnesbitt142/pcgeos-1-sdk-v2).

- Pfeiltasten oder W A S D, **P** = Pause, **R** = Neustart
- Schnecke läuft nach dem ersten Tastendruck selbstständig weiter und wird mit jedem Ziel länger und schneller
- Spielfeld und Fenster passen sich der Fenstergröße an, bei großen Fenstern mit doppelter Zellgröße
- Highscore in `GEOWORKS\STATE\SCHNECKE.SCO`
- Eigenes Icon

Die ausführliche deutsche Anleitung steht in [liesmich.txt](liesmich.txt). Das fertige Spiel ist [g1snake.geo](g1snake.geo).

## Selbst bauen

SDK klonen, den Patch aus `sdk-patch/icon-support.patch` anwenden (Icon- und Fenstergrößen-Unterstützung), `snake-asm/` nach `examples/snake-asm/` kopieren und bauen:

```
perl sdk.pl build --project examples/snake-asm
```

Voraussetzungen: Perl und NASM.
