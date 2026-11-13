defmodule Tymeslot.Meetings.EmailVerificationTokenTest do
  @moduledoc """
  The link token sent to an attendee. What matters is that it binds to the
  meeting and the deadline it was issued for, and that it never carries the
  meeting uid, which opens the public cancel and reschedule pages.
  """

  use Tymeslot.DataCase, async: true

  import Tymeslot.Factory

  @moduletag :bookings
  @moduletag :meetings

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Meetings.EmailVerificationToken
  alias Tymeslot.Repo
  alias Tymeslot.SignedToken

  defp held_meeting(user_attrs \\ %{}) do
    user = insert(:user, user_attrs)

    insert(:meeting, %{
      status: :awaiting_verification,
      organizer_user: user,
      organizer_user_id: user.id,
      verification_deadline_at: DateTime.add(DateTime.utc_now(:second), 30, :minute)
    })
  end

  test "a token verifies for its meeting" do
    meeting = held_meeting()

    assert {:ok, verified} =
             meeting |> EmailVerificationToken.sign() |> EmailVerificationToken.verify()

    assert verified.id == meeting.id
  end

  test "a token for a meeting whose deadline changed is stale" do
    meeting = held_meeting()
    token = EmailVerificationToken.sign(meeting)

    meeting
    |> Changeset.change(
      verification_deadline_at: DateTime.add(meeting.verification_deadline_at, 1, :minute)
    )
    |> Repo.update!()

    assert {:error, :stale} = EmailVerificationToken.verify(token)
  end

  test "a token for a meeting without a deadline is stale" do
    meeting = held_meeting()
    token = EmailVerificationToken.sign(meeting)

    meeting |> Changeset.change(verification_deadline_at: nil) |> Repo.update!()

    assert {:error, :stale} = EmailVerificationToken.verify(token)
  end

  test "a token for a deleted meeting is not found" do
    meeting = held_meeting()
    token = EmailVerificationToken.sign(meeting)

    Repo.delete!(meeting)

    assert {:error, :not_found} = EmailVerificationToken.verify(token)
  end

  test "a token for an organiser pending deletion is not found" do
    meeting = held_meeting()
    token = EmailVerificationToken.sign(meeting)

    Repo.get!(UserSchema, meeting.organizer_user_id)
    |> Changeset.change(deletion_scheduled_at: DateTime.utc_now(:second))
    |> Repo.update!()

    assert {:error, :not_found} = EmailVerificationToken.verify(token)
  end

  test "a tampered token is invalid" do
    token = EmailVerificationToken.sign(held_meeting())

    assert {:error, :invalid} = EmailVerificationToken.verify(token <> "x")
    assert {:error, :invalid} = EmailVerificationToken.verify("not-a-token")
  end

  test "a token older than two days has expired" do
    meeting = held_meeting()
    token = EmailVerificationToken.sign(meeting)

    assert {:error, :expired} =
             SignedToken.verify(:booking_email_verification, token, max_age: -1)
  end

  test "a payload of another shape is invalid" do
    token = SignedToken.sign(:booking_email_verification, {:unexpected, 1})

    assert {:error, :invalid} = EmailVerificationToken.verify(token)
  end

  test "the token does not contain the meeting uid" do
    meeting = held_meeting()
    token = EmailVerificationToken.sign(meeting)

    [_header, payload, _signature] = String.split(token, ".")
    decoded = payload |> Base.url_decode64!(padding: false) |> :erlang.binary_to_term([:safe])

    refute inspect(decoded) =~ meeting.uid
    refute payload =~ meeting.uid
  end
end
