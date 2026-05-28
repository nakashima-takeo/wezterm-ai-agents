# WezTerm での非同期実行

WezTerm の Lua は **Lua 5.4**。Promise / async-await は無い。イベントコールバックは GUI スレッド上で動くため、ブロッキング処理は UI をフリーズさせる。本プラグインで外部コマンドや遅延処理を書くときの判断指針。

## 使うべき API（3つだけ）

| API | 性質 | 使う場面 |
|---|---|---|
| `wezterm.run_child_process(args)` | 完了を待ち `(success, stdout, stderr)` を返す | 出力・成否が必要。コルーチン内（通常のイベント／`action_callback`）なら GUI を止めない |
| `wezterm.background_child_process(args)` | 背景起動・戻り値なし | 出力不要の投げっぱなし（fetch、エディタ起動など） |
| `wezterm.time.call_after(秒, fn)` | 指定秒後にコールバック | デバウンス、遅延再描画、疑似タイマー。引数は**秒**（ms は `/1000`） |

`io.popen` / `os.execute` は**使わない**。WezTerm の async 機構を経由せず GUI を直接ブロックする。

## 判断フロー

1. **出力が要らない** → `background_child_process`
2. **出力が要る & 軽い & コルーチン内** → `run_child_process`（GUI を止めない）
3. **出力が要る & 重い／高頻度** → 背景で取得してキャッシュ。読む側は同期 read だけ
4. **同期描画イベント（`format-tab-title` / `format-window-title`）の中** → `run_child_process` を呼ぶと `attempt to yield from outside a coroutine` エラーになる。事前に取得済みの値だけ使う

## 重い処理はキャッシュで回避する

`update-status` 等の高頻度イベントで毎回外部コマンドを叩かない。本プラグインの実装パターン（`worktree.lua` の `prefetch`）:

```lua
-- 切替時に背景で fetch / gh を実行し、結果をキャッシュファイルへ
function M.prefetch(git_root)
  wezterm.background_child_process({ "git", "-C", git_root, "fetch", "--prune" })
  local cmd = ("cd %s && %s > %s 2>/dev/null && mv %s %s"):format(...)
  wezterm.background_child_process({ "/bin/sh", "-c", cmd })
end
-- UI 側はキャッシュを読むだけ（同期コマンドを走らせない）
```

書き込みは `tmp + mv`（rename）でアトミックに。読む側が壊れた中間状態を見ないようにする。

## 完了は待てない

ウィンドウ生成・プロセス spawn は非同期だが await できない。タイミングが必要なら `call_after` で後続を遅延させる。`sleep_ms` は非同期ではなくスクリプトを止める同期 sleep なので、イベント内では使わない。

## 出典

- [run_child_process](https://wezterm.org/config/lua/wezterm/run_child_process.html) / [background_child_process](https://wezterm.org/config/lua/wezterm/background_child_process.html) / [call_after](https://wezterm.org/config/lua/wezterm.time/call_after.html)
- [format-tab-title（同期イベントの制約）](https://github.com/wezterm/wezterm/blob/main/docs/config/lua/window-events/format-tab-title.md)
- [Discussion #1632（run_child_process は内部で async/await 相当）](https://github.com/wezterm/wezterm/discussions/1632)
