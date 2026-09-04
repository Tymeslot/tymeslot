defmodule Tymeslot.Repo.Migrations.AddBookingTextToProfiles do
  use Ecto.Migration

  @moduledoc """
  Lets an organiser replace the booking page's introductory heading, greeting
  and instruction with their own wording.

  The three strings live here rather than on `theme_customizations` because
  they are theme-independent: that table is keyed `(profile_id, theme_id)` and
  capability-gated per theme, so text stored there would reset on a theme
  switch and would need a permanently-true capability flag. Every theme with an
  overview step renders all three.

  `booking_text_enabled` is the on/off switch. Turning it off keeps the stored
  wording so it comes back intact when it is turned on again, which is why the
  three columns stay nullable and are not cleared here.
  """

  def change do
    alter table(:profiles) do
      # The default is load-bearing: every existing profile must keep rendering
      # the translated theme defaults, so it cannot be NULL-then-backfill.
      # Postgres 11+ records a non-volatile default in the catalogue instead of
      # rewriting the table, so the ACCESS EXCLUSIVE lock covers a catalogue
      # update rather than a full scan.
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add(:booking_text_enabled, :boolean, null: false, default: false)

      # `:text`, not a sized varchar: the length caps are enforced in the
      # changeset, which counts graphemes, while Postgres counts characters. An
      # emoji spanning several code points passes one and trips the other, so
      # the column stays unbounded and the changeset stays the single authority.
      add(:booking_heading, :text)
      add(:booking_greeting, :text)
      add(:booking_instruction, :text)
    end
  end
end
