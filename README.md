# edge-no-rounded-frame

Removes the forced rounded "frame" (rounded corners + margin) that recent
Microsoft Edge builds draw around the web content area — the border that used to
be switchable via `edge://flags/#edge-rounded-containers` and that no longer has
any setting or flag in current Edge.

Works on **Microsoft Edge 154.0.4258.53** (verified), and on any build where the
internal feature `msForceNoRoundedCornerAndMargin` still exists.

```
without the switch:  content 1079 x 670   window 1100 x 761
with the switch:     content 1087 x 674   window 1100 x 761
                                 +8 x +4 px  <- the frame
```

## Usage

```powershell
# apply (asks for admin rights once, for the machine-wide Start Menu shortcut)
powershell -ExecutionPolicy Bypass -File .\EdgeNoRoundedFrame.ps1

# prove the switch works on your build (temporary Edge profile, no changes)
powershell -ExecutionPolicy Bypass -File .\EdgeNoRoundedFrame.ps1 -Test

# revert everything
powershell -ExecutionPolicy Bypass -File .\EdgeNoRoundedFrame.ps1 -Undo
```

Or just double-click `Run.cmd`.

**After applying: close Edge completely** (Task Manager: no `msedge.exe` left)
and start it again from a normal shortcut. A running Edge process ignores the
switch for new windows — that is exactly why this script also disables
"Startup boost" and the background mode.

Extra options: `-NoElevate`, `-SkipPolicies`, `-SkipProtocolHandlers`,
`-Quiet`, `-BackupDir <path>`.

## How it works

Edge renders the page inside an internal "central container" view. The old
`edge://flags` entry was deleted from the binary, but the feature that disables
the container is still compiled into `msedge.dll`:

```
--enable-features=msForceNoRoundedCornerAndMargin
```

The script writes that command-line switch into everything that can start Edge:

| target | why |
|---|---|
| Start Menu (machine + user), Desktop, Public Desktop, Quick Launch, taskbar pin | normal browser starts |
| `microsoft-edge:`, `MSEdgeHTM`, `MSEdgePDF`, `MSEdgeMHT` protocol/file handlers (`HKCU\Software\Classes`) | links opened from other applications |
| `StartupBoostEnabled = 0`, `BackgroundModeEnabled = 0` (`HKLM\SOFTWARE\Policies\Microsoft\Edge`) | otherwise a pre-launched background Edge process accepts the new window and the switch is silently ignored |

Every change is recorded in `%LOCALAPPDATA%\EdgeNoRoundedFrame\backup.json`
together with copies of the original shortcuts and exported `.reg` files, so
`-Undo` restores the exact previous state.

## Reverse engineering notes

Found by static analysis of `msedge.dll` (333 MB, PE32+, `imageBase = 0x180000000`):

| item | location |
|---|---|
| `msForceNoRoundedCornerAndMargin` (`base::Feature`, `.data`) | file offset `0x13E07738`, `default_state = 0` = disabled by default |
| `msAppLayerForCentralContainer` | `0x13E07710`, enabled by default |
| `msVisualRejuvMicaCentralContainer` | `0x13E07AA8`, disabled by default |
| `msFeatureGroupNewLookAndFeelHoldout` | `0x13E07648`, enabled by default |
| `msRoundedCornerRadius`, `msMarginForPhoenix` (feature params) | `.rdata` `0x125A41F0`, `0x125A4208` |
| implementation | `chrome/browser/ui/views/frame/edge_rounded_corner_view.h` |
| old flag string `rounded-containers` | **0 occurrences** — the flag was removed from the build |

The feature name appears in the Edge feature table next to
`msContainerizeVerticalTabContainer`, `msPhoenixShowContainersInEdge` and
friends, so `msForceNoRoundedCornerAndMargin` is a real registered feature
(`--enable-features=...` is accepted, no `Unrecognized feature` warning), and its
default state is *disabled*, which makes the override meaningful.

`-Test` measures `window.innerWidth/Height` through the DevTools HTTP endpoint of
a throwaway profile with and without the switch, so you can re-verify after every
Edge update.

## What `-Undo` restores

The script keeps a manifest of everything it touched
(`%LOCALAPPDATA%\EdgeNoRoundedFrame\backup.json`) plus copies of the original
shortcuts and exported `.reg` files. `-Undo` writes back the exact previous
argument string / registry value and removes the overrides it created itself.

If a shortcut or a handler was already patched by an earlier run — or by hand —
the script *adopts* it: it records the current state with the switch stripped out,
so `-Undo` can still revert it. Overrides and policy values that cannot be traced
back are treated as "created by us" and are removed on undo.

Every write is verified by reading the value back, so a failed write (for example
a machine-wide shortcut without administrator rights) is reported as a warning
instead of a fake success.

After a complete undo the manifest is deleted. If elevation was declined, the
manifest is kept so you can finish from an elevated PowerShell.

## Compatibility and caveats

* Windows 10 / 11, Windows PowerShell 5.1 or PowerShell 7+.
* The switch is an undocumented Edge feature. Microsoft may remove it in a future
  build — re-run `-Test` to check.
* Edge updates can recreate the Start Menu shortcut without the switch; just run
  the script again (it is idempotent). The `HKCU\Software\Classes` overrides
  survive updates.
* Setting the two policies makes Edge show "managed by your organization" in
  `edge://policy`. Use `-SkipPolicies` if you do not want that, but then the
  switch may be ignored while a background Edge process is alive.
* `-Undo` needs the same rights as the patch (admin, for the machine-wide parts).

## Кратко по-русски

Скрипт убирает принудительную рамку (скругление + отступ) вокруг страницы в Edge.
Внутренняя фича `msForceNoRoundedCornerAndMargin` найдена в `msedge.dll` (сборка
154): старый флаг `edge-rounded-containers` из браузера вырезан, а эта — нет.
Скрипт дописывает `--enable-features=msForceNoRoundedCornerAndMargin` в ярлыки и
обработчики ссылок, выключает Startup boost и фоновый режим, делает бэкап и
умеет откатываться (`-Undo`) и проверяться (`-Test`). После применения Edge надо
закрыть полностью и запустить заново.

## License

[MIT](LICENSE)
