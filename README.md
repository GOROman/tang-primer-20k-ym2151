# Tang Primer 20K YM2151 Player

Tang Primer 20K Dockで、JT51によるYM2151 (OPM)音源、X68000 ADPCM、PT8211ステレオDAC、720p HDMIレジスタモニターを動かす実験プロジェクトです。

## 現在の機能

- JT51 YM2151互換コア
- `Flash! Flash! Flash!` のイベントストリーム再生
- BOS.PDXから抽出した曲中ADPCMサンプル
- PT8211ステレオ出力（62.5 kHz）
- S2/S3による5%刻みの音量調整
- 1280x720 HDMI出力
- 256個のOPMレジスタを16x16グリッド表示
- 最近変化したレジスタをシアンでハイライト
- DDR3 IP、外部音声アップロード、フレームバッファ不使用

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

## リソース使用量（現在）

- Logic: 約31%
- BSRAM: 46/46
- rPLL: 2/4
- CLKDIV: 1/8

## 由来とライセンス

- JT51: JOTego、GPL-3.0（Git submodule）
- HDMI DVI TX、PLL、PT8211ドライバ: Sipeed TangPrimer-20K-example由来
- 本リポジトリはGPL-3.0です。

`music/`内の生成済みデータは動作再現用です。元のMDX/PDXファイルは収録していません。
