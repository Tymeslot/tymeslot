defmodule Tymeslot.Repo.Migrations.AddLocaleDefaultsToAppSettings do
  use Ecto.Migration

  # Two nullable columns on the app_settings singleton, holding the locale each
  # surface falls back to when no locale can be detected for a request. Nil
  # means "no admin override", the same way every other setting on this table
  # spells its absence, so existing rows need no backfill: an install that has
  # never touched these keeps falling back to `:locales`'s configured default.
  def change do
    alter table(:app_settings) do
      add(:admin_default_locale, :string)
      add(:booking_default_locale, :string)
    end
  end
end
