# Core2 + Muse Gadget SDK

Meta's [Muse Gadget SDK](https://github.com/facebookincubator/muse-gadget-sdk)
turns an ESP32 board into a Muse device: the Jollybot avatar UI,
push-to-talk voice notes, and commands Muse can call. This repo adds two
patches on top of upstream commit `812c46f` (2026-10-09).

## Patch 1: Core2 v1.1 support

Upstream supports only the **Core2 v1.0**, whose power chip (PMU) is an
AXP192. The **v1.1** uses an **AXP2101** at the same I2C address (0x34) but
with a different register map. **Don't flash the upstream `core2` build on a
v1.1**: its AXP192 register writes would land on unrelated AXP2101 registers.
Check the revision on the back sticker, or in the factory firmware's boot
log (`Axp2101 Found`).

What the patch does:

- **Rails and backlight.** Espressif's `m5stack_core_2` BSP (≥ 3.0.3)
  already supports the v1.1 through its `BSP_PMU_AXP2101` option: LCD rails
  ALDO2/ALDO4, backlight BLDO1, speaker ALDO3. The new
  `devices/sdkconfig.muse-m5stack-core2-v11` selects that option.
- **The board file's own PMU code** (`board_m5stack_core2.c`) gets AXP2101
  branches. The register details come from M5Unified's `AXP2101_Class` and
  its Core2 v1.1 setup:

  | Function | AXP192 (v1.0) | AXP2101 (v1.1) |
  |---|---|---|
  | Power-key events (short / long) | `0x46` bits 1/0 | `0x49` bits 3/2, cleared by write-back |
  | Battery voltage | `0x78`, 12 bit × 1.1 mV | `0x34–0x35`, 14 bit × 1 mV |
  | Charging | `0x00` bit 2 | `0x01` bits 6:5 = `01` |
  | USB / battery present | `0x00` bit 5 / `0x01` bit 5 | `0x00` bit 5 / bit 3 |
  | ADCs on | `0x82 = 0xff` | `0x30 = 0x0f` |
  | Backlight off | DCDC3 (`0x12` bit 1) | BSP cuts BLDO1 at 0% |
  | Power off | `0x32` bit 7 | `0x10` bit 0 |

- **A separate `core2v11` profile** in `tools/muse/board.sh`, `ports.py` and
  `avatar.py`. The board reports itself as `M5Stack Core2 v1.1`, so Meta's
  avatar tool rebuilds the right profile and can't fall back to the v1.0 build.
- **Tests.** `tests/test_core2_buttons.py` runs its button scenarios against
  both PMUs' register layouts. The full host suite passes (226 tests).

## Patch 2: `glasses.capture`

A new command, `glasses.capture`, behind the option
`CONFIG_HOMEHUB_GLASSES_CAPTURE`.

- **What Muse sees:** the command's description tells Muse it returns "what
  the user is looking at right now", so Muse calls it for questions about
  what you see, are reading, holding or eating.
- **What the gadget does:** fetches `CONFIG_HOMEHUB_GLASSES_CAPTURE_URL`
  (the PC relay's `/snapshot.jpg`) in a background task, then returns the
  base64 JPEG. Large results are split into 8 KB chunks by the SDK's control
  stream.
- **Errors:** if the relay is unreachable or the glasses aren't streaming,
  Muse gets a clear error, for example "the glasses are not streaming".

## Build and flash

You need **ESP-IDF v6.0.1** exactly (the SDK says so):

```sh
git clone -b v6.0.1 --depth 1 --recursive --shallow-submodules https://github.com/espressif/esp-idf ~/esp/esp-idf-v6.0.1
~/esp/esp-idf-v6.0.1/install.sh esp32
```

Then, from this repo:

```sh
muse-gadget/setup.sh                 # clone the SDK at 812c46f and apply the patches (branch core2-v1.1)
muse-gadget/build.sh                 # build; reads GADGET_SDK_TOKEN and GLASSES_RELAY_URL from .env
muse-gadget/build.sh "" flash        # build and flash (port found by USB ID: CH9102 or CP2104)
```

The SDK token comes from gadgets.muse.ai → Account → SDK tokens. The script
writes it and the relay URL into the git-ignored build directory's
`sdkconfig`, never into source.

**First flash:** back up the Core2 first (`scripts/backup_core2.sh`). Erase
the flash so old firmware data doesn't sit where Muse keeps its settings:

```sh
python -m esptool --chip esp32 -p /dev/ttyACM0 -b 230400 erase-flash
```

A healthy boot logs `muse: board: M5Stack Core2 v1.1`, `LCD panel create
success`, `Setting LCD backlight: 100%` and `advertising as MuseGadget-XXXXXX`.
The warning `esp_psram: Virtual address not enough for PSRAM … 4MB is mapped`
is normal on the classic ESP32.

## Pair and use

1. **Pair.** In the Muse app: Settings → Devices → **Developer mode** on →
   **+** → `MuseGadget-XXXXXX`, then enter your Wi-Fi (2.4 GHz). Confirm by
   tapping the touch strip under the screen.
2. **Ask.** **Hold the middle of the touch strip** (BtnB), speak, release.
   Replies appear as captions.
3. **Power button.** A tap sleeps or wakes the screen. Holding it shuts down
   cleanly; the PMU forces power off at about 4 s.
4. **Glasses.** Start streaming in Glasses Bridge, then ask "What am I looking
   at?". The relay prints `[snapshot] served … bytes to <core2 ip>`.

## Running the SDK tests

`board.sh` deletes `managed_components/` after each build, and the host
tests compile against its cJSON. Restore it with a `reconfigure` first:

```sh
cd <sdk>/esp32 && . ~/esp/esp-idf-v6.0.1/export.sh
idf.py -B build-muse-m5stack-core2-v11 -DIDF_TARGET=esp32 -DSDKCONFIG=build-muse-m5stack-core2-v11/sdkconfig \
  -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;devices/sdkconfig.muse;devices/sdkconfig.muse-m5stack-core2-v11" reconfigure
python3 -m unittest discover -s tests -p 'test_*.py'
```
