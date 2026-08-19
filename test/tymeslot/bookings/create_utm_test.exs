defmodule Tymeslot.Bookings.CreateUtmTest do
  @moduledoc """
  Integration tests for UTM / tracking parameter persistence via
  `Tymeslot.Bookings.Create.execute/3`.
  """

  use Tymeslot.DataCase, async: false
  @moduletag :bookings

  alias __MODULE__.MockCalendar
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  import Tymeslot.AvailabilityTestHelpers

  defmodule MockCalendar do
    @moduledoc """
    Lightweight mock calendar module used to keep `Bookings.Create` from
    reaching real calendar integrations during these tests.
    """
    use Agent

    @spec start_link() :: {:ok, pid()} | {:error, term()}
    def start_link do
      Agent.start_link(
        fn -> %{response: {:ok, []}, integration_info: {:error, :no_integration}} end,
        name: __MODULE__
      )
    end

    @spec get_events_for_range_fresh(integer(), Date.t(), Date.t()) ::
            {:ok, list()} | {:error, term()}
    def get_events_for_range_fresh(_user_id, _start_date, _end_date) do
      Agent.get(__MODULE__, & &1.response)
    end

    @spec get_booking_integration_info(integer() | map()) :: {:ok, map()} | {:error, term()}
    def get_booking_integration_info(_context) do
      Agent.get(__MODULE__, & &1.integration_info)
    end

    @spec stop() :: :ok
    def stop do
      case Process.whereis(__MODULE__) do
        nil ->
          :ok

        _pid ->
          try do
            Agent.stop(__MODULE__)
          catch
            :exit, _reason -> :ok
          end
      end
    end
  end

  setup do
    {:ok, _pid} = MockCalendar.start_link()

    original_module = Application.get_env(:tymeslot, :calendar_module)
    Application.put_env(:tymeslot, :calendar_module, MockCalendar)

    on_exit(fn ->
      MockCalendar.stop()

      if original_module do
        Application.put_env(:tymeslot, :calendar_module, original_module)
      else
        Application.delete_env(:tymeslot, :calendar_module)
      end
    end)

    {:ok, ctx: build_executable_booking_context()}
  end

  describe "execute/3 tracking persistence" do
    test "persists UTM and tracking_params from meeting_params", %{ctx: ctx} do
      tracking = %{
        utm_source: "linkedin",
        utm_medium: "social",
        utm_campaign: "spring",
        utm_content: nil,
        utm_term: nil,
        referrer_host: "linkedin.com",
        tracking_params: %{"ref" => "newsletter"}
      }

      meeting_params = Map.merge(ctx.meeting_params, tracking)

      assert {:ok, meeting} = Create.execute(meeting_params, ctx.form_data, [])

      saved = Repo.get!(MeetingSchema, meeting.id)
      assert saved.utm_source == "linkedin"
      assert saved.utm_medium == "social"
      assert saved.utm_campaign == "spring"
      assert saved.utm_content == nil
      assert saved.utm_term == nil
      assert saved.referrer_host == "linkedin.com"
      assert saved.tracking_params == %{"ref" => "newsletter"}
    end

    test "creates a meeting without tracking when none provided", %{ctx: ctx} do
      assert {:ok, meeting} = Create.execute(ctx.meeting_params, ctx.form_data, [])

      saved = Repo.get!(MeetingSchema, meeting.id)
      assert saved.utm_source == nil
      assert saved.utm_medium == nil
      assert saved.utm_campaign == nil
      assert saved.utm_content == nil
      assert saved.utm_term == nil
      assert saved.referrer_host == nil
      assert saved.tracking_params == %{}
    end
  end

  # Builds a valid meeting_params + form_data pair that `Bookings.Create.execute/3`
  # will accept, on top of a freshly inserted user/profile.
  defp build_executable_booking_context do
    # Tracking params are the subject here, so the host offers every hour of
    # every day and the schedule never refuses the booking.
    %{user: user} = create_always_bookable_profile(timezone: "America/New_York")

    meeting_params = %{
      date: Date.add(Date.utc_today(), 1),
      time: "14:00",
      duration: "60min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id
    }

    form_data = %{
      "name" => "Test Attendee",
      "email" => "attendee@test.com",
      "message" => "Test message"
    }

    %{user: user, meeting_params: meeting_params, form_data: form_data}
  end
end
