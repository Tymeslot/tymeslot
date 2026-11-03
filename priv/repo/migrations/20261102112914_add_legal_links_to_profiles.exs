defmodule Tymeslot.Repo.Migrations.AddLegalLinksToProfiles do
  use Ecto.Migration

  @moduledoc """
  Lets an organiser link their own legal notice (imprint) and privacy policy
  from their booking page.

  Both live on the profile because they belong to the organiser, not to a
  theme: every theme that shows them reads the same two fields.

  Both columns are nullable with no default, so existing profiles simply have
  no links and nothing is rewritten. `:text` rather than a sized varchar, for
  the reason `AddBookingTextToProfiles` gives: the changeset validates the
  URL and its length and is the one authority on the cap.
  """

  def change do
    alter table(:profiles) do
      add(:legal_notice_url, :text)
      add(:privacy_policy_url, :text)
    end
  end
end
