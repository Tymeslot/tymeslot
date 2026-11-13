defmodule Tymeslot.Repo.Migrations.AddVerificationEmailsSentToMeetings do
  use Ecto.Migration

  # How many verification emails a held booking has been sent, so resends can
  # be capped. Nullable with no default: NULL reads as the one email sent with
  # the booking, which is true of every gated row written before this column
  # and meaningless on an ungated one.
  def change do
    alter table(:meetings) do
      add(:verification_emails_sent, :integer)
    end
  end
end
