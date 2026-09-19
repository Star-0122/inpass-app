-- ============================================================
-- インパス（INPASS）追加スキーマ（差分）
-- ------------------------------------------------------------
-- 既存の schema.sql は変更していません。これは追加分のみです。
-- Supabaseダッシュボード → SQL Editor に貼り付けて実行してください。
-- ============================================================

-- 1人のユーザーが同じイベントのチケットを複数枚取得できるようにするため、
-- 以前設定した「1ユーザー1イベント1枚まで」の制約を削除する。
-- （制約名は Postgres が自動生成したデフォルト名です。エラーになる場合は
--  Table Editor の tickets テーブル → 制約一覧で実際の名前を確認してください）
alter table public.tickets drop constraint if exists tickets_event_id_user_id_key;

-- ユーザーは「まだ使用されていない（valid）」自分のチケットのみ削除できる。
-- すでに使用済み（used）のチケットは、チェックイン履歴の監査性を保つため
-- 削除できないようにする（RLSで自動的に拒否される）。
create policy "tickets_delete_own_valid_only" on public.tickets
  for delete using (user_id = auth.uid() and status = 'valid');
