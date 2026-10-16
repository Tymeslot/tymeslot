defmodule Tymeslot.Repo.Migrations.AddHeadlineAndBioToProfiles do
  use Ecto.Migration

  @moduledoc """
  Lets an organiser introduce themselves on the booking page: a one-line
  headline under their name and a short plain-text bio.

  Both live on the profile rather than in a theme's customisation settings
  because they describe the organiser, not a theme's look: every theme that
  shows them reads the same two fields, and switching theme keeps them.

  Both columns are nullable with no default, so existing profiles simply have
  no introduction and nothing is rewritten. `:text` rather than a sized
  varchar, for the reason `AddBookingTextToProfiles` gives: the changeset
  counts graphemes and is the one authority on the caps.
  """

  def change do
    alter table(:profiles) do
      add(:headline, :text)
      add(:bio, :text)
    end
  end
end
