defmodule Tymeslot.Repo.Migrations.AddBookingLanguages do
  @moduledoc """
  Lets an organiser say which language their texts are written in, which
  languages they translate them into, and whether the booking page is offered
  in every interface language or only in theirs.

    * `translations` on the four records whose texts reach invitees
      (`profiles`, `booking_pages`, `meeting_types`, `venues`):
      `%{locale => %{path => %{"text" => ..., "source" => ...}}}`. A meeting
      type's questions and locations are translated through its own map, keyed
      by path, so the embeds themselves are untouched.
    * `profiles.content_locale` (nullable: unset means the booking pages'
      fallback language), `translation_locales` and `offer_all_locales`
      (true keeps today's behaviour).
    * `meetings.attendee_texts`: the attendee's copies of the booking's
      snapshot strings, in the attendee's language, stored only when they were
      actually translated.

  Every new NOT NULL column has a constant default, so existing rows satisfy
  it without a backfill.
  """
  use Ecto.Migration

  # A constant default is a metadata-only change on Postgres 11+, so adding
  # these columns rewrites no table.
  # excellent_migrations:safety-assured-for-this-file column_added_with_default

  @translated_tables [:profiles, :booking_pages, :meeting_types, :venues]

  def change do
    for table_name <- @translated_tables do
      alter table(table_name) do
        add(:translations, :map, null: false, default: %{})
      end
    end

    alter table(:profiles) do
      add(:content_locale, :string)
      add(:translation_locales, {:array, :string}, null: false, default: [])
      add(:offer_all_locales, :boolean, null: false, default: true)
    end

    alter table(:meetings) do
      add(:attendee_texts, :map)
    end
  end
end
