defmodule Tymeslot.Repo.Migrations.AddVerificationEmailsSentToMeetingParticipants do
  use Ecto.Migration

  # How many verification emails a held seat has been sent, so resends can be
  # capped, as `meetings.verification_emails_sent` does for a one-to-one
  # booking. Nullable with no default: NULL reads as the one email sent with
  # the seat, which is true of every gated seat written before this column
  # and meaningless on an ungated one.
  def change do
    alter table(:meeting_participants) do
      add(:verification_emails_sent, :integer)
    end
  end
end
