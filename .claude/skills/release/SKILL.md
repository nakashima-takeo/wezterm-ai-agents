---
name: release
description: wezterm-ai-agents のリリースを実行する。dev → main マージ、タグ打ち、GitHub Release 検証まで自動で行う。
argument-hint: v0.2.0
disable-model-invocation: true
allowed-tools: Bash,Read
---

dev ブランチから main へのマージ・タグ・リリースを実行する。引数にバージョン番号（`v0.2.0` 形式）を取る。

バージョン番号が引数にない場合は AskUserQuestion で聞く。`v` プレフィックスがなければ付与する。

# 手順

## 1. 差分確認

```bash
git fetch origin
git log origin/main..origin/dev --oneline
```

差分が 0 件なら「リリースする変更がありません」と報告して終了。

## 2. dev を push

ローカル dev に未 push のコミットがあれば `git push origin dev` する。

## 3. PR 作成

dev → main の PR が既にあれば、そのまま使う（新規作成しない）。

```bash
gh pr create --base main --head dev --title "Release $VERSION" --body ""
```

## 4. CI 待ち

```bash
gh pr checks <PR番号> --watch
```

1つでも fail があれば「CI が失敗しました」と PR URL を報告して終了。

## 5. マージ

```bash
gh pr merge <PR番号> --merge --delete-branch=false
```

## 6. タグ・push

```bash
git fetch origin main
git tag $VERSION origin/main
git push origin $VERSION
```

## 7. リリース検証

```bash
gh run list --limit 1
gh run watch <run_id>
gh release view $VERSION
```

Release ワークフローが成功し、リリースが作成されたことを確認する。失敗した場合は報告して終了。

## 8. dev 同期

```bash
git checkout dev
git merge origin/main --no-edit
git push origin dev
```

## 9. 完了報告

リリース URL (`https://github.com/nakashima-takeo/wezterm-ai-agents/releases/tag/$VERSION`) を返して終了。
