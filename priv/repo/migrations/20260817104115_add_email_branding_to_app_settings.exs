defmodule Tymeslot.Repo.Migrations.AddEmailBrandingToAppSettings do
  use Ecto.Migration

  # Three nullable columns on the app_settings singleton. Nil means "no admin
  # override", which is how every other setting on this table already spells
  # its absence, so existing rows need no backfill: an install that has never
  # touched these keeps the stock Tymeslot logo and turquoise accent.
  def change do
    alter table(:app_settings) do
      add(:email_brand_accent, :string)
      add(:email_brand_name, :string)
      add(:email_logo_path, :string)
    end
  end
end
