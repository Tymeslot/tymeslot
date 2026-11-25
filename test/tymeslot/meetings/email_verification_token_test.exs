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
  alias Tymeslot.Meetings.ParticipantSchema
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

  describe "a seat token" do
    defp held_seat(seat_attrs \\ %{}) do
      user = insert(:user)

      slot =
        insert(:group_meeting, %{
          organizer_user: user,
          organizer_user_id: user.id,
          status: :confirmed
        })

      seat =
        insert(
          :participant,
          Map.merge(
            %{
              meeting: slot,
              meeting_id: slot.id,
              verification_deadline_at: DateTime.add(DateTime.utc_now(:second), 30, :minute)
            },
            seat_attrs
          )
        )

      {slot, seat}
    end

    test "a seat token verifies to its seat" do
      {slot, seat} = held_seat()

      assert {:ok, {:seat, participant, meeting}} =
               seat |> EmailVerificationToken.sign_seat() |> EmailVerificationToken.verify()

      assert participant.id == seat.id
      assert meeting.id == slot.id
    end

    test "a seat token for a cancelled seat is still decoded but the page reads it as expired" do
      {_slot, seat} = held_seat()
      token = EmailVerificationToken.sign_seat(seat)

      seat |> Changeset.change(cancelled_at: DateTime.utc_now(:second)) |> Repo.update!()

      assert {:ok, {:seat, participant, _meeting}} = EmailVerificationToken.verify(token)
      refute ParticipantSchema.live?(participant)
    end

    test "a seat token whose deadline changed is stale, and one for a gone seat is not found" do
      {_slot, seat} = held_seat()
      token = EmailVerificationToken.sign_seat(seat)

      seat
      |> Changeset.change(
        verification_deadline_at: DateTime.add(seat.verification_deadline_at, 1, :minute)
      )
      |> Repo.update!()

      assert {:error, :stale} = EmailVerificationToken.verify(token)

      Repo.delete!(seat)
      assert {:error, :not_found} = EmailVerificationToken.verify(token)
    end

    test "a seat token never contains the management token" do
      {_slot, seat} = held_seat()
      token = EmailVerificationToken.sign_seat(seat)

      [_header, payload, _signature] = String.split(token, ".")
      decoded = payload |> Base.url_decode64!(padding: false) |> :erlang.binary_to_term([:safe])

      refute inspect(decoded) =~ seat.management_token
      refute payload =~ seat.management_token
    end
  end
end
