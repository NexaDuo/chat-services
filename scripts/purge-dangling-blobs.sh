#!/usr/bin/env bash
# =============================================================================
# purge-dangling-blobs.sh — remove Chatwoot ActiveStorage blob records whose
# underlying file is ABSENT from the storage service (the chatwoot-storage
# Docker volume, DiskService).
#
# WHY (issue #61): a DB-only restore (pg_dump) leaves `active_storage_blobs`
# rows pointing at files that were never restored (the chatwoot-storage volume
# is NOT captured by pg_dump — see AGENTS.md "pg_dump is NOT a full backup").
# Serving such a blob (e.g. a Contact avatar variant via
# ActiveStorage::Representations::RedirectController#show) raises
# ActiveStorage::FileNotFoundError → HTTP 500. Purging the dangling rows via
# the ActiveStorage API (blob.purge → also removes attachments + variant
# records) makes the app fall back to a generated/default avatar instead of
# 500-ing.
#
# SAFETY:
#   - DRY-RUN by default: lists MISSING blobs and their attachments, purges
#     NOTHING. Pass --apply (or PURGE_APPLY=1) to actually purge.
#   - Uses `blob.service.exist?(blob.key)` as the source of truth, so a file
#     that IS present on disk is NEVER touched.
#   - Idempotent: re-running after a purge finds nothing to do.
#
# Usage:
#   scripts/purge-dangling-blobs.sh            # dry-run (diff only)
#   scripts/purge-dangling-blobs.sh --apply    # purge the MISSING blobs
# =============================================================================
set -euo pipefail

APPLY="${PURGE_APPLY:-0}"
[[ "${1:-}" == "--apply" ]] && APPLY=1

RAILS="${CHATWOOT_RAILS_CONTAINER:-nexaduo-chatwoot-rails-1}"

echo "[purge-dangling-blobs] container=$RAILS apply=$APPLY"

docker exec -e PURGE_APPLY="$APPLY" "$RAILS" bundle exec rails runner '
apply = ENV["PURGE_APPLY"] == "1"
missing = ActiveStorage::Blob.order(:id).reject { |b| b.service.exist?(b.key) rescue false }
if missing.empty?
  puts "[purge-dangling-blobs] no dangling blobs — every blob file is present on disk. Nothing to do."
else
  puts "[purge-dangling-blobs] #{missing.size} dangling blob(s) (file MISSING on disk):"
  missing.each do |b|
    atts = ActiveStorage::Attachment.where(blob_id: b.id).map { |a| "#{a.record_type}##{a.record_id}/#{a.name}" }
    puts "  - id=#{b.id} key=#{b.key} filename=#{b.filename} attached=[#{atts.join(", ")}]"
  end
  if apply
    missing.each do |b|
      puts "[purge-dangling-blobs] purging id=#{b.id} key=#{b.key}"
      # Purge via the attachment(s) so ActiveStorage detaches the record, drops
      # dependent variant records, and removes the blob. A bare `blob.purge`
      # would raise (and silently rescue) InvalidForeignKey while attachments
      # still reference the row, leaving the dangling blob in place.
      atts = ActiveStorage::Attachment.where(blob_id: b.id).to_a
      atts.each(&:purge)
      # No attachment (or leftover row): destroy variant records then the blob.
      if ActiveStorage::Blob.exists?(b.id)
        ActiveStorage::VariantRecord.where(blob_id: b.id).delete_all
        ActiveStorage::Blob.find(b.id).destroy
      end
    end
    puts "[purge-dangling-blobs] purged #{missing.size} dangling blob(s)."
  else
    puts "[purge-dangling-blobs] DRY-RUN — nothing purged. Re-run with --apply to purge the above."
  end
end
'
