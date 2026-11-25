defmodule Tymeslot.SeatVerificationHelpers do
  @moduledoc """
  Group slots and seats for tests of the email verification gate on a seat.

  `slot/3` takes the test context carrying `:user`, `:type` and
  `:start_time`, as `context/1` builds it.
  """

  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Repo

  @doc """
  An always bookable organiser in New York with a three-seat, one-hour type,
  and a start time two days out at 14:00 their time.
  """
  @spec context(map()) :: map()
  def context(_ctx) do
    %{user: user} = create_always_bookable_profile(timezone: "America/New_York")
    type = insert(:meeting_type, user: user, duration_minutes: 60, max_participants: 3)
    date = Date.add(Date.utc_today(), 2)

    start_time =
      date |> DateTime.new!(~T[14:00:00], "America/New_York") |> DateTime.shift_zone!("Etc/UTC")

    %{user: user, type: type, date: date, start_time: start_time}
  end

  @doc """
  A group slot for the context's type at its start time, with no seats. A
  held slot carries a verification deadline, as one booked through the gate
  does, which is what keeps it from the organiser.
  """
  @spec slot(map(), atom(), keyword()) :: MeetingSchema.t()
  def slot(ctx, status, attrs \\ []) do
    defaults = [
      status: status,
      verification_deadline_at: slot_deadline(status),
      organizer_user_id: ctx.user.id,
      organizer_email: ctx.user.email,
      meeting_type_id: ctx.type.id,
      start_time: ctx.start_time,
      end_time: DateTime.add(ctx.start_time, 1, :hour),
      duration: 60,
      capacity: 3,
      video_integration_id: nil
    ]

    insert(:group_meeting, Keyword.merge(defaults, attrs))
  end

  @doc "A seat held for its booker to verify, by default for 30 minutes."
  @spec held_seat(MeetingSchema.t(), String.t(), DateTime.t() | nil, keyword()) ::
          ParticipantSchema.t()
  def held_seat(slot, email, deadline \\ nil, attrs \\ []) do
    deadline = deadline || DateTime.add(DateTime.utc_now(:second), 30, :minute)

    insert(
      :participant,
      [meeting: slot, email: email, verification_deadline_at: deadline] ++ attrs
    )
  end

  @doc "An ungated seat, which counts and shows."
  @spec visible_seat(MeetingSchema.t(), String.t(), keyword()) :: ParticipantSchema.t()
  def visible_seat(slot, email, attrs \\ []),
    do: insert(:participant, [meeting: slot, email: email] ++ attrs)

  @doc "The slot or seat as stored now."
  @spec reload(MeetingSchema.t() | ParticipantSchema.t()) ::
          MeetingSchema.t() | ParticipantSchema.t()
  def reload(%MeetingSchema{id: id}), do: Repo.get!(MeetingSchema, id)
  def reload(%ParticipantSchema{id: id}), do: Repo.get!(ParticipantSchema, id)

  defp slot_deadline(:awaiting_verification),
    do: DateTime.add(DateTime.utc_now(:second), 30, :minute)

  defp slot_deadline(_status), do: nil
end
