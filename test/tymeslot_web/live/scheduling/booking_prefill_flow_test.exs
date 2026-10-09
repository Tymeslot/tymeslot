defmodule TymeslotWeb.Live.Scheduling.BookingPrefillFlowTest do
  @moduledoc """
  A booking link carrying `#name=…&email=…` opens the booking form with the
  attendee's details already filled in, so an organiser booking on someone's
  behalf only has to pick the slot.

  The browser reads the fragment and sends it with the LiveView connection
  (`attendee_prefill` in the connect params), which is what these tests drive.
  The fragment reading itself is covered by `attendee_prefill.test.js`.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :bookings
  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.BookingTestHelpers
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  @name_input "#booking-form input[name='booking[name]']"
  @email_input "#booking-form input[name='booking[email]']"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    # Submitting without a reCAPTCHA token; the gate is orthogonal to prefill.
    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    TestMocks.setup_all_mocks()

    user = insert(:user)
    profile = BookingTestHelpers.bookable_profile(user, "1", "prefill-host")
    insert(:meeting_type, user: user, duration_minutes: 30, name: "Intro", is_active: true)

    %{profile: profile}
  end

  @tag :capture_log
  test "the booking is made for the attendee the link named", %{conn: conn, profile: profile} do
    view =
      conn
      |> put_connect_params(%{
        "attendee_prefill" => %{"name" => "Ada Lovelace", "email" => "ada@example.com"}
      })
      |> walk_to_form(profile)

    assert input_value(view, @name_input) == "Ada Lovelace"
    assert input_value(view, @email_input) == "ada@example.com"

    # Only the message is typed; name and email are submitted as prefilled.
    view
    |> form("#booking-form", %{"booking" => %{"message" => "Agreed on the phone"}})
    |> render_submit()

    _drain = :sys.get_state(view.pid)

    assert [meeting] = Repo.all_by(MeetingSchema, attendee_email: "ada@example.com")
    assert meeting.attendee_name == "Ada Lovelace"
  end

  @tag :capture_log
  test "a value the form would refuse is left blank rather than shown", %{
    conn: conn,
    profile: profile
  } do
    view =
      conn
      |> put_connect_params(%{
        "attendee_prefill" => %{"name" => "Ada Lovelace", "email" => "not-an-address"}
      })
      |> walk_to_form(profile)

    assert input_value(view, @name_input) == "Ada Lovelace"
    assert input_value(view, @email_input) in [nil, ""]
  end

  @tag :capture_log
  test "without a prefill the form starts blank", %{conn: conn, profile: profile} do
    view = walk_to_form(conn, profile)

    assert input_value(view, @name_input) in [nil, ""]
    assert input_value(view, @email_input) in [nil, ""]
  end

  defp walk_to_form(conn, profile) do
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{profile.timezone}")
    view = BookingTestHelpers.walk_to_booking_form(view, profile.timezone)
    assert has_element?(view, "#booking-form")
    view
  end

  defp input_value(view, selector) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.attribute(selector, "value")
    |> List.first()
  end
end
