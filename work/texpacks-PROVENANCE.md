# work/texpacks — where the texture packs came from

Gitignored (`.gitignore`: `work/texpacks/`). These are **other people's
assets**, fetched at test time and deletable: nothing in the build or the gate
needs them to exist, and this file is what makes deleting them safe.

## PD Plus HD Textures v0.09d

The reference pack for the Phase 2 texture-pack item, and the one upstream's
own Community Packs catalogue carries
(`vendor/dabs-mod/port/src/community.c`: repo `retro-foundry/Perfect-Dark-Plus-HD-Textures`,
match `TEXTURE.PACK`, avoid `QUEST`, install name `PD Plus HD`, bottomUp 1).
By Parabolee of Retro Foundry; the XBLA release's textures upscaled, several
hundred redrawn by hand, fonts by Trov.

Re-fetch exactly what was used here:

```sh
mkdir -p work/texpacks
curl -sL -o work/texpacks/PD.PLUS.HD.TEXTURE.PACK.v0.09d.zip \
  https://github.com/retro-foundry/Perfect-Dark-Plus-HD-Textures/releases/download/Beta_Release_V0.09/PD.PLUS.HD.TEXTURE.PACK.v0.09d.zip
```

| | |
|---|---|
| release tag | `Beta_Release_V0.09` (2026-09-08) |
| asset | `PD.PLUS.HD.TEXTURE.PACK.v0.09d.zip` |
| bytes | 179 720 191 |
| sha256 | `55859d090945341e487f2be9e7bd7a83d58f04689acf4c4c276f8aff4f7b67f2` |
| contents | 4152 files, top folder `PD Plus HD/` |

The release also carries `…QUEST.STANDALONE…` (the Quest build, 127 MB) and a
Joanna outfit pack — the catalogue's `avoid: QUEST` is what keeps the picker
off the first of those, and the same rule was followed by hand here.

**The top folder is `PD Plus HD`, not `ext_tex`, and there is no
`bottomup.txt` inside it.** That is the row-order trap in full: unpacked and
dropped in by hand, every texture in this pack draws upside down.
`app/ios/PDTexPacks.m` writes the marker, which is what upstream's own
installer does (`CLAUDE-notes/texture-packs.md`, "The marker is the point").
