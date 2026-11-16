defmodule Tymeslot.Bookings.CreateRequiresMeetingTypeTest do
  @moduledoc """
  A booking is always made under one of the organiser's meeting types.

  Approval, email confirmation, payment, the type's schedule, buffers, limits
  and questions are all read from the type, so a booking saved without one
  would be held to none of them. A booking page that reached the submit with
  no type resolved (a `?duration=` link the page never turned into its type)
  saved exactly that, and told the visitor the meeting was confirmed.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings

  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()

    # An always-open host with a gated type: the time is free, so nothing but
    # the missing type can be the reason a booking is refused.
    %{user: user} = create_always_bookable_profile(timezone: "America/New_York")

    gated =
      insert(:meeting_type, user: user, duration_minutes: 30, requires_approval: true)

    params = %{
      date: Date.add(Date.utc_today(), 1),
      time: "14:00",
      duration: "30min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id
    }

    form = %{"name" => "Test Attendee", "email" => "attendee@test.com", "message" => ""}

    %{gated: gated, params: params, form: form}
  end

  test "a booking with no meeting type is refused, and nothing is saved", %{
    params: params,
    form: form
  } do
    assert {:error, :meeting_type_not_found} =
             Create.execute(Map.put(params, :meeting_type_id, nil), form)

    assert Repo.aggregate(MeetingSchema, :count) == 0
  end

  test "the same booking under the type is held by the type's rules", %{
    gated: gated,
    params: params,
    form: form
  } do
    assert {:ok, meeting} = Create.execute(Map.put(params, :meeting_type_id, gated.id), form)
    assert meeting.meeting_type_id == gated.id
    assert meeting.status == :awaiting_approval
  end
end
