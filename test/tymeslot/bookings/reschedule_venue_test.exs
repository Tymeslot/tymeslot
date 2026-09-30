defmodule Tymeslot.Bookings.RescheduleVenueTest do
  @moduledoc """
  A reschedule of an in-person meeting held at a saved venue, through
  `Tymeslot.Bookings.Reschedule.execute/4`: the booker may switch venue
  within the location, a time-only reschedule never moves the meeting (not
  even when its venue has been deleted or dropped from the location), a move
  to another location keeps the meeting's venue wherever that location
  offers it, and a venue switch has no provider side.

  The provider-room side of location moves is pinned in
  `Tymeslot.Bookings.RescheduleLocationTest`.
  """

  # Not async, like `RescheduleLocationTest`: a reschedule goes through the
  # application-wide circuit breakers, which DataCase only resets between
  # non-async modules.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :integration

  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.MeetingTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Venues
  alias Tymeslot.Workers.{VideoRoomWorker, VideoSyncWorker}

  setup do
    TestMocks.setup_email_mocks()
    TestMocks.stub_no_calendar_events()

    %{user: user} = create_always_bookable_profile()
    mirotalk = insert(:video_integration, user: user, provider: "mirotalk", is_active: true)
    berlin = insert(:venue, user: user, name: "Berlin office", description: "Friedrichstrasse 1")
    munich = insert(:venue, user: user, name: "Munich office", description: "Marienplatz 8")
    offices = in_person_location([berlin, munich], id: "loc-offices", label: "Our offices")

    %{user: user, mirotalk: mirotalk, berlin: berlin, munich: munich, offices: offices}
  end

  defp video_on(integration) do
    %LocationOption{
      id: "loc-video",
      kind: "video",
      label: "Video call",
      video_integration_ids: [integration.id],
      position: 1
    }
  end

  defp meeting_on(user, locations, meeting_attrs) do
    meeting_type =
      insert(:meeting_type,
        user: user,
        user_id: user.id,
        duration_minutes: 60,
        locations: locations
      )

    insert_meeting_for_user(
      user,
      Map.merge(%{meeting_type_id: meeting_type.id, status: "confirmed"}, meeting_attrs)
    )
  end

  defp reschedule(meeting, choice) do
    params =
      Map.merge(
        %{
          date: Date.to_string(Date.add(Date.utc_today(), 2)),
          time: "2:00 PM",
          duration: "60min",
          user_timezone: "America/New_York"
        },
        choice
      )

    assert {:ok, _updated} =
             Reschedule.execute(meeting.uid, params, %{}, meeting.organizer_user_id)

    # Read back, so every assertion is about what was persisted.
    Repo.get!(MeetingSchema, meeting.id)
  end

  defp booked_in_berlin(berlin) do
    %{
      location: "Berlin office (Friedrichstrasse 1)",
      location_kind: "in_person",
      location_option_id: "loc-offices",
      venue_id: berlin.id
    }
  end

  defp booked_in_munich(munich) do
    %{
      location: "Munich office (Marienplatz 8)",
      location_kind: "in_person",
      location_option_id: "loc-offices",
      venue_id: munich.id
    }
  end

  test "moves the meeting to the venue the booker picked", ctx do
    meeting = meeting_on(ctx.user, [ctx.offices], booked_in_berlin(ctx.berlin))

    updated =
      reschedule(meeting, %{
        location_option_id: "loc-offices",
        location_venue_id: to_string(ctx.munich.id)
      })

    assert updated.venue_id == ctx.munich.id
    assert updated.location == "Munich office (Marienplatz 8)"
    assert updated.location_kind == "in_person"

    # A venue switch has no provider side at all.
    refute_enqueued(worker: VideoSyncWorker)
    refute_enqueued(worker: VideoRoomWorker)
  end

  # Booked at the option's second venue, so falling back to the first one
  # would be visible.
  test "an unknown venue id keeps the meeting where it is", ctx do
    meeting = meeting_on(ctx.user, [ctx.offices], booked_in_munich(ctx.munich))

    updated =
      reschedule(meeting, %{location_option_id: "loc-offices", location_venue_id: 987_654_321})

    assert updated.venue_id == ctx.munich.id
    assert updated.location == "Munich office (Marienplatz 8)"
  end

  # The picker sends no venue today, only the option. The venue is renamed
  # first, so an unchanged location text shows the reschedule left the
  # location alone rather than resolving it afresh.
  test "a time-only reschedule keeps the venue and its booked text", ctx do
    meeting = meeting_on(ctx.user, [ctx.offices], booked_in_munich(ctx.munich))
    {:ok, _renamed} = Venues.update_venue(ctx.munich, %{"name" => "Munich HQ"})

    updated = reschedule(meeting, %{location_option_id: "loc-offices"})

    assert updated.venue_id == ctx.munich.id
    assert updated.location == "Munich office (Marienplatz 8)"
  end

  test "staying at the same venue keeps the booked text, even after the venue was edited",
       ctx do
    meeting = meeting_on(ctx.user, [ctx.offices], booked_in_berlin(ctx.berlin))
    {:ok, _renamed} = Venues.update_venue(ctx.berlin, %{"name" => "Berlin HQ"})

    updated =
      reschedule(meeting, %{
        location_option_id: "loc-offices",
        location_venue_id: ctx.berlin.id
      })

    assert updated.venue_id == ctx.berlin.id
    assert updated.location == "Berlin office (Friedrichstrasse 1)"
  end

  # The location still offers another venue, so falling back to it would be
  # visible.
  test "a time-only reschedule of a meeting whose venue was deleted leaves it where it was",
       ctx do
    meeting = meeting_on(ctx.user, [ctx.offices], booked_in_berlin(ctx.berlin))
    {:ok, _deleted} = Venues.delete_venue(ctx.berlin)

    updated = reschedule(meeting, %{location_option_id: "loc-offices"})

    assert updated.venue_id == nil
    assert updated.location == "Berlin office (Friedrichstrasse 1)"
    assert updated.address_to_arrange == false
  end

  test "a time-only reschedule keeps a venue the location no longer lists", ctx do
    meeting = meeting_on(ctx.user, [ctx.offices], booked_in_berlin(ctx.berlin))

    MeetingTypeSchema
    |> Repo.get!(meeting.meeting_type_id)
    |> Changeset.change(
      locations: [in_person_location([ctx.munich], id: "loc-offices", label: "Our offices")]
    )
    |> Repo.update!()

    updated = reschedule(meeting, %{location_option_id: "loc-offices"})

    assert updated.venue_id == ctx.berlin.id
    assert updated.location == "Berlin office (Friedrichstrasse 1)"
  end

  test "picking a venue the location offers still moves a meeting whose venue was deleted",
       ctx do
    meeting = meeting_on(ctx.user, [ctx.offices], booked_in_berlin(ctx.berlin))
    {:ok, _deleted} = Venues.delete_venue(ctx.berlin)

    updated =
      reschedule(meeting, %{location_option_id: "loc-offices", location_venue_id: ctx.munich.id})

    assert updated.venue_id == ctx.munich.id
    assert updated.location == "Munich office (Marienplatz 8)"
  end

  test "moving to another location that also lists the meeting's venue keeps that venue",
       ctx do
    # Berlin comes first on the other location too, so without the
    # meeting's own venue as a preference the move would land there.
    branches =
      in_person_location([ctx.berlin, ctx.munich],
        id: "loc-branches",
        label: "Branches",
        position: 1
      )

    meeting =
      meeting_on(ctx.user, [ctx.offices, branches], %{
        location: "Munich office (Marienplatz 8)",
        location_kind: "in_person",
        location_option_id: "loc-offices",
        venue_id: ctx.munich.id
      })

    updated = reschedule(meeting, %{location_option_id: "loc-branches"})

    assert updated.location_option_id == "loc-branches"
    assert updated.venue_id == ctx.munich.id
    assert updated.location == "Munich office (Marienplatz 8)"
  end

  test "moving to a video location leaves the venue behind", ctx do
    meeting =
      meeting_on(
        ctx.user,
        [ctx.offices, video_on(ctx.mirotalk)],
        booked_in_berlin(ctx.berlin)
      )

    updated = reschedule(meeting, %{location_option_id: "loc-video"})

    assert updated.location_kind == "video"
    assert updated.video_integration_id == ctx.mirotalk.id
    assert updated.venue_id == nil
  end

  describe "the address to be arranged" do
    setup do
      arranged = in_person_location([], id: "loc-arranged", label: "In person", position: 1)
      %{arranged: arranged}
    end

    defp booked_to_arrange do
      %{
        location: "In person",
        location_kind: "in_person",
        location_option_id: "loc-arranged",
        venue_id: nil,
        address_to_arrange: true
      }
    end

    test "is settled by moving to a location with a venue", ctx do
      meeting = meeting_on(ctx.user, [ctx.offices, ctx.arranged], booked_to_arrange())

      updated =
        reschedule(meeting, %{
          location_option_id: "loc-offices",
          location_venue_id: ctx.munich.id
        })

      assert updated.venue_id == ctx.munich.id
      assert updated.address_to_arrange == false
    end

    test "is recorded by moving from a venue to a location offering none", ctx do
      meeting = meeting_on(ctx.user, [ctx.offices, ctx.arranged], booked_in_berlin(ctx.berlin))

      updated = reschedule(meeting, %{location_option_id: "loc-arranged"})

      assert updated.venue_id == nil
      assert updated.location == "In person"
      assert updated.address_to_arrange == true
    end

    # The booked text differs from the location's label, so an unchanged text
    # shows the reschedule left the location alone rather than resolving it
    # afresh, which would also record the address as to be arranged.
    test "stays recorded on a time-only reschedule", ctx do
      meeting =
        meeting_on(
          ctx.user,
          [ctx.offices, ctx.arranged],
          %{booked_to_arrange() | location: "In person (as booked)"}
        )

      updated = reschedule(meeting, %{location_option_id: "loc-arranged"})

      assert updated.address_to_arrange == true
      assert updated.location == "In person (as booked)"
    end
  end
end
