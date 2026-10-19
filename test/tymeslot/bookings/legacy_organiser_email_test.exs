defmodule Tymeslot.Bookings.LegacyOrganiserEmailTest do
  @moduledoc """
  A host whose stored address predates the email format rules must still
  take bookings. The organiser address on a meeting is copied from the
  host's account, never typed by the visitor, so only the attendee's
  address is held to the format rules.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :bookings
  @moduletag :integration

  alias Ecto.Changeset
  alias Tymeslot.Bookings.{Create, CreateAdHoc}
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  # The booking reads the host's calendars before committing; these hosts have
  # nothing in them.
  setup do
    TestMocks.stub_no_calendar_events()
    :ok
  end

  import Tymeslot.AvailabilityTestHelpers

  @legacy_address ~s("legacy"@example.com)

  # Calendar conflicts are not under test here.

  setup do
    TestMocks.setup_all_mocks()
    %{user: user} = create_always_bookable_profile(timezone: "Etc/UTC")
    # Written past the changeset, as an account created before the rules was.
    user = user |> Changeset.change(email: @legacy_address) |> Repo.update!()
    %{user: user}
  end

  defp booking_params(user) do
    %{
      date: Date.add(Date.utc_today(), 5),
      time: "2:00 PM",
      duration: "60min",
      user_timezone: "Etc/UTC",
      organizer_user_id: user.id
    }
  end

  defp form_data(email), do: %{"name" => "Test Attendee", "email" => email, "message" => "Hi"}

  test "a visitor's booking succeeds under the host's stored address", %{user: user} do
    assert {:ok, meeting} =
             Create.execute(booking_params(user), form_data("attendee@test.com"))

    assert Repo.get!(MeetingSchema, meeting.id).organizer_email == @legacy_address
  end

  test "the host's own ad hoc booking succeeds under the stored address", %{user: user} do
    start_time = DateTime.new!(Date.add(Date.utc_today(), 5), ~T[15:00:00], "Etc/UTC")

    assert {:ok, meeting} =
             CreateAdHoc.execute(%{
               title: "Catch-up",
               start_time: start_time,
               end_time: DateTime.add(start_time, 30, :minute),
               attendee_name: "Jane Doe",
               attendee_email: "jane@example.com",
               attendee_timezone: "Etc/UTC",
               organizer_user_id: user.id,
               calendar_integration_id: nil,
               calendar_path: nil,
               video_integration_id: nil
             })

    assert Repo.get!(MeetingSchema, meeting.id).organizer_email == @legacy_address
  end

  test "an attendee address outside the format rules is still refused", %{user: user} do
    assert {:error, _reason} =
             Create.execute(booking_params(user), form_data(~s("guest"@example.com)))

    assert Repo.all(MeetingSchema) == []
  end
end
