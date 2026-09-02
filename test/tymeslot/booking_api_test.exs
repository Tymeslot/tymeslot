defmodule Tymeslot.BookingApiTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.TestMocks

  alias Tymeslot.BookingApi
  alias Tymeslot.Locales
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Profiles.ProfileQueries

  @moduletag :bookings

  setup do
    setup_calendar_mocks()

    user = insert(:user)
    profile = insert(:profile, user: user, username: "api-host", full_name: "Ada Host")

    {:ok, profile} = BookingApi.enable(profile)

    %{user: user, profile: profile}
  end

  defp body(overrides \\ %{}) do
    start_time =
      DateTime.utc_now()
      |> DateTime.add(2, :day)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    Map.merge(
      %{
        "title" => "Discovery call",
        "attendee_name" => "Robin Vale",
        "attendee_email" => "robin@example.com",
        "start_time" => start_time,
        "duration_minutes" => 30
      },
      overrides
    )
  end

  defp violation_fields({:error, {:invalid_params, violations}}),
    do: Enum.map(violations, & &1.field)

  describe "token lifecycle" do
    test "enable/1 issues a token and is idempotent", %{profile: profile} do
      assert BookingApi.enabled?(profile)
      assert byte_size(profile.booking_api_token) > 0

      assert {:ok, unchanged} = BookingApi.enable(profile)
      assert unchanged.booking_api_token == profile.booking_api_token
    end

    test "regenerate_token/1 replaces the token", %{profile: profile} do
      assert {:ok, regenerated} = BookingApi.regenerate_token(profile)
      refute regenerated.booking_api_token == profile.booking_api_token
      assert BookingApi.enabled?(regenerated)
    end

    test "disable/1 clears the token and closes the endpoint", %{profile: profile} do
      assert {:ok, disabled} = BookingApi.disable(profile)
      refute BookingApi.enabled?(disabled)
      assert {:error, :not_found} = BookingApi.authenticate(profile.booking_api_token)
    end

    test "authenticate/1 resolves a live token to its organiser", %{
      profile: profile,
      user: user
    } do
      assert {:ok, found} = BookingApi.authenticate(profile.booking_api_token)
      assert found.user_id == user.id
    end

    test "authenticate/1 refuses an unknown or blank token" do
      assert {:error, :not_found} = BookingApi.authenticate("nope")
      assert {:error, :not_found} = BookingApi.authenticate("")
    end

    test "a regenerated token no longer answers to the old one", %{profile: profile} do
      old = profile.booking_api_token
      assert {:ok, _regenerated} = BookingApi.regenerate_token(profile)
      assert {:error, :not_found} = BookingApi.authenticate(old)
    end
  end

  describe "create_booking/3 request validation" do
    test "names every missing required field at once", %{profile: profile} do
      result = BookingApi.create_booking(profile, %{})

      assert violation_fields(result) == [
               "attendee_name",
               "attendee_email",
               "start_time",
               "end_time",
               "title"
             ]
    end

    test "rejects an address that is not an email", %{profile: profile} do
      result = BookingApi.create_booking(profile, body(%{"attendee_email" => "robin"}))

      assert violation_fields(result) == ["attendee_email"]
    end

    test "rejects a timestamp with no UTC offset", %{profile: profile} do
      assert {:error, {:invalid_params, [%{field: "start_time", message: message}]}} =
               BookingApi.create_booking(profile, body(%{"start_time" => "2026-09-01T09:00:00"}))

      assert message =~ "UTC offset"
    end

    test "rejects an end_time that is not after start_time", %{profile: profile} do
      start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      result =
        BookingApi.create_booking(
          profile,
          body(%{
            "start_time" => DateTime.to_iso8601(start_time),
            "end_time" => start_time |> DateTime.add(-1, :hour) |> DateTime.to_iso8601(),
            "duration_minutes" => nil
          })
        )

      assert violation_fields(result) == ["end_time"]
    end

    test "rejects end_time and duration_minutes together", %{profile: profile} do
      start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      result =
        BookingApi.create_booking(
          profile,
          body(%{
            "start_time" => DateTime.to_iso8601(start_time),
            "end_time" => start_time |> DateTime.add(30, :minute) |> DateTime.to_iso8601()
          })
        )

      assert violation_fields(result) == ["duration_minutes"]
    end

    test "requires a duration when neither end_time nor meeting_type is given", %{
      profile: profile
    } do
      result = BookingApi.create_booking(profile, body(%{"duration_minutes" => nil}))

      assert violation_fields(result) == ["end_time"]
    end

    test "rejects an unknown time zone", %{profile: profile} do
      result = BookingApi.create_booking(profile, body(%{"attendee_timezone" => "Mars/Olympus"}))

      assert violation_fields(result) == ["attendee_timezone"]
    end

    test "rejects a language the instance does not serve", %{profile: profile} do
      result = BookingApi.create_booking(profile, body(%{"attendee_locale" => "kl"}))

      assert violation_fields(result) == ["attendee_locale"]
    end

    test "rejects a language that is not a string", %{profile: profile} do
      result = BookingApi.create_booking(profile, body(%{"attendee_locale" => 42}))

      assert violation_fields(result) == ["attendee_locale"]
    end

    test "rejects a guest list holding something that is not an email", %{profile: profile} do
      result =
        BookingApi.create_booking(profile, body(%{"guest_emails" => ["ok@example.com", 7]}))

      assert violation_fields(result) == ["guest_emails"]
    end

    test "ignores keys the endpoint does not model", %{profile: profile} do
      assert {:ok, :created, _meeting} =
               BookingApi.create_booking(profile, body(%{"internal_crm_id" => "42"}))
    end
  end

  describe "create_booking/3" do
    test "books the attendee and returns their action links", %{profile: profile, user: user} do
      assert {:ok, :created, %MeetingSchema{} = meeting} =
               BookingApi.create_booking(profile, body())

      assert meeting.organizer_user_id == user.id
      assert meeting.attendee_name == "Robin Vale"
      assert meeting.attendee_email == "robin@example.com"
      assert meeting.title == "Discovery call"
      assert meeting.duration == 30
      assert meeting.status == "confirmed"
      assert meeting.cancel_url =~ meeting.uid
      assert meeting.reschedule_url =~ meeting.uid
    end

    test "defaults the attendee time zone to UTC", %{profile: profile} do
      assert {:ok, :created, meeting} = BookingApi.create_booking(profile, body())
      assert meeting.attendee_timezone == "Etc/UTC"
    end

    test "defaults the attendee language to the instance booking default", %{profile: profile} do
      assert {:ok, :created, meeting} = BookingApi.create_booking(profile, body())
      assert meeting.attendee_locale == Locales.booking_default_locale()
    end

    test "honours an explicit attendee language", %{profile: profile} do
      assert {:ok, :created, meeting} =
               BookingApi.create_booking(profile, body(%{"attendee_locale" => "fr"}))

      assert meeting.attendee_locale == "fr"
    end

    test "honours an explicit end_time", %{profile: profile} do
      start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      assert {:ok, :created, meeting} =
               BookingApi.create_booking(
                 profile,
                 body(%{
                   "start_time" => DateTime.to_iso8601(start_time),
                   "end_time" => start_time |> DateTime.add(90, :minute) |> DateTime.to_iso8601(),
                   "duration_minutes" => nil
                 })
               )

      assert meeting.duration == 90
    end

    test "refuses to book the organiser as their own attendee", %{profile: profile, user: user} do
      assert {:error, message} =
               BookingApi.create_booking(profile, body(%{"attendee_email" => user.email}))

      assert message =~ "must differ"
    end
  end

  describe "create_booking/3 with a meeting type" do
    setup %{user: user} do
      meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Product demo",
          slug: "product-demo",
          duration_minutes: 45
        )

      %{meeting_type: meeting_type}
    end

    test "takes its name and duration from the meeting type", %{profile: profile} do
      assert {:ok, :created, meeting} =
               BookingApi.create_booking(
                 profile,
                 body(%{
                   "title" => nil,
                   "duration_minutes" => nil,
                   "meeting_type" => "product-demo"
                 })
               )

      assert meeting.title == "Product demo with Robin Vale"
      assert meeting.duration == 45
    end

    test "an explicit title wins over the meeting type's name", %{profile: profile} do
      assert {:ok, :created, meeting} =
               BookingApi.create_booking(
                 profile,
                 body(%{"duration_minutes" => nil, "meeting_type" => "product-demo"})
               )

      assert meeting.title == "Discovery call"
      assert meeting.duration == 45
    end

    test "refuses an unknown slug", %{profile: profile} do
      assert {:error, :meeting_type_not_found} =
               BookingApi.create_booking(profile, body(%{"meeting_type" => "no-such-type"}))
    end

    test "refuses another organiser's meeting type", %{profile: profile} do
      other = insert(:user)
      insert(:meeting_type, user: other, slug: "someone-elses")

      assert {:error, :meeting_type_not_found} =
               BookingApi.create_booking(profile, body(%{"meeting_type" => "someone-elses"}))
    end

    test "refuses an inactive meeting type", %{profile: profile, user: user} do
      insert(:meeting_type, user: user, slug: "retired", is_active: false)

      assert {:error, :meeting_type_not_found} =
               BookingApi.create_booking(profile, body(%{"meeting_type" => "retired"}))
    end

    test "refuses a paid meeting type, which has to go through checkout", %{
      profile: profile,
      user: user
    } do
      insert(:meeting_type,
        user: user,
        slug: "paid-session",
        payment_required: true,
        price_cents: 5000
      )

      assert {:error, :meeting_type_requires_payment} =
               BookingApi.create_booking(profile, body(%{"meeting_type" => "paid-session"}))
    end
  end

  describe "create_booking/3 availability" do
    test "refuses a slot the organiser's calendar already fills", %{profile: profile} do
      start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      setup_calendar_mocks(
        events: [
          mock_calendar_event(
            summary: "Already booked",
            start_time: start_time,
            end_time: DateTime.add(start_time, 30, :minute)
          )
        ]
      )

      assert {:error, :slot_unavailable} =
               BookingApi.create_booking(
                 profile,
                 body(%{"start_time" => DateTime.to_iso8601(start_time)})
               )
    end

    test "force: true books over a full calendar", %{profile: profile} do
      start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      setup_calendar_mocks(
        events: [
          mock_calendar_event(
            summary: "Already booked",
            start_time: start_time,
            end_time: DateTime.add(start_time, 30, :minute)
          )
        ]
      )

      assert {:ok, :created, _meeting} =
               BookingApi.create_booking(
                 profile,
                 body(%{"start_time" => DateTime.to_iso8601(start_time), "force" => true})
               )
    end

    test "books anyway when the calendar cannot be read", %{profile: profile} do
      setup_calendar_mocks(result: {:error, :provider_unreachable})

      assert {:ok, :created, _meeting} = BookingApi.create_booking(profile, body())
    end
  end

  describe "create_booking/3 idempotency" do
    test "a repeat under the same key returns the first booking", %{profile: profile} do
      assert {:ok, :created, first} = BookingApi.create_booking(profile, body(), "crm-1")
      assert {:ok, :replayed, second} = BookingApi.create_booking(profile, body(), "crm-1")

      assert first.id == second.id
      assert Repo.aggregate(MeetingSchema, :count) == 1
    end

    test "a different key books again", %{profile: profile} do
      later =
        DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)

      assert {:ok, :created, _first} = BookingApi.create_booking(profile, body(), "crm-1")

      assert {:ok, :created, _second} =
               BookingApi.create_booking(
                 profile,
                 body(%{"start_time" => DateTime.to_iso8601(later)}),
                 "crm-2"
               )

      assert Repo.aggregate(MeetingSchema, :count) == 2
    end

    test "the same key belongs to one organiser only", %{profile: profile} do
      other_user = insert(:user)
      other_profile = insert(:profile, user: other_user, username: "other-host")
      {:ok, other_profile} = BookingApi.enable(other_profile)

      assert {:ok, :created, _first} = BookingApi.create_booking(profile, body(), "crm-1")
      assert {:ok, :created, _second} = BookingApi.create_booking(other_profile, body(), "crm-1")

      assert Repo.aggregate(MeetingSchema, :count) == 2
    end

    test "a rejected request leaves its key free to retry", %{profile: profile} do
      assert {:error, {:invalid_params, _violations}} =
               BookingApi.create_booking(profile, body(%{"attendee_email" => "nope"}), "crm-1")

      assert {:ok, :created, _meeting} = BookingApi.create_booking(profile, body(), "crm-1")
    end

    test "a booking refused by the domain also frees its key", %{profile: profile, user: user} do
      assert {:error, _message} =
               BookingApi.create_booking(
                 profile,
                 body(%{"attendee_email" => user.email}),
                 "crm-1"
               )

      assert {:ok, :created, _meeting} = BookingApi.create_booking(profile, body(), "crm-1")
    end
  end

  describe "the endpoint stays closed until an organiser opens it" do
    test "a profile starts with no token" do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "quiet-host")

      refute BookingApi.enabled?(profile)

      {:ok, reloaded} = ProfileQueries.get_by_user_id(user.id)
      assert is_nil(reloaded.booking_api_token)
    end
  end
end
