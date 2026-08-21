# Tang Primer 20K YM2151 Player

Tang Primer 20K Dockで、JT51によるYM2151 (OPM)音源、DDR3へのUART曲転送、PT8211ステレオDAC、720p HDMIレジスタモニターを動かす実験プロジェクトです。

## 現在の機能

- JT51 YM2151互換コア
- YS II `TO MAKE THE END OF BATTLE` のイベントストリーム再生
- 230400 bps、1 KiB XMODEM-CRCによるDDR3曲転送
- UARTコマンドによる再生、停止、リスタート
- PT8211ステレオ出力（62.5 kHz）
- S2/S3による5%刻みの音量調整
- 1280x720 HDMI出力
- 256個のOPMレジスタを16x16グリッド表示
- 最近変化したレジスタをシアンでハイライト
- DDR3書込み後の全データCRC検証
- 曲終了時の自動消音

## 必要環境

- Sipeed Tang Primer 20K Core + Dock
- Gowin IDE（macOS版でも `gw_sh` によるCLIビルド可）
- `openFPGALoader`

## セットアップ

```sh
git clone --recursive https://github.com/GOROman/tang-primer-20k-ym2151.git
cd tang-primer-20k-ym2151
```

## macOSでビルド

```sh
GOWIN_LIB='/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/lib'
DYLD_LIBRARY_PATH="$GOWIN_LIB" DYLD_FRAMEWORK_PATH="$GOWIN_LIB" \
  "$GOWIN_LIB/../bin/gw_sh" run.tcl
```

## SRAMへ転送

```sh
openFPGALoader -b tangprimer20k -v impl/pnr/project.fs
```

## 曲データをUART転送

```sh
python3 -m pip install pyserial
python3 tools/load_audio_xmodem.py music/ys2_to_make_end_lzss.hex \
  --port /dev/cu.usbserial-1101
```

DDR3への転送とCRC検証後、自動的に再生を開始します。FPGAの再ビルドは不要です。

## UART再生コマンド

230400 bpsで1文字送信します。正常に受理すると`K`が返ります。

- `P` / `p`: 先頭から再生
- `R` / `r`: リスタート
- `S` / `s`: 停止

## リソース使用量（現在）

- Logic: ビルドレポートを参照
- BSRAM: ビルドレポートを参照
- rPLL: 2/4
- CLKDIV: 1/8

## 由来とライセンス

- JT51: JOTego、GPL-3.0（Git submodule）
- HDMI DVI TX、PLL、PT8211ドライバ: Sipeed TangPrimer-20K-example由来
- 本リポジトリはGPL-3.0です。

`music/`内の生成済みデータは動作再現用です。元のMDXファイルは収録していません。
