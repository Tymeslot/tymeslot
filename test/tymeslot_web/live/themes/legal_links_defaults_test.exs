defmodule TymeslotWeb.Live.Themes.LegalLinksDefaultsTest do
  @moduledoc """
  The instance's default legal links on public pages: a booking page whose
  organiser set none shows the default, and a payment return page shows no
  footer at all on its dead render (it does not know the organiser yet, so a
  default could stand in for a link they replaced), then the organiser's own
  once connected.

  Not async: the instance defaults are application-wide configuration.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :profiles

  import Mox
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]
  import Tymeslot.ConfigTestHelpers, only: [setup_config: 3]
  import Tymeslot.Factory

  alias Tymeslot.Profiles
  alias Tymeslot.TestMocks

  @footer "footer[data-testid='legal-links']"
  @default_privacy "https://host.example/privacy"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    setup_config(:tymeslot, :booking_privacy_policy_url, @default_privacy)
  end

  test "falls back to the instance default", %{conn: conn} do
    %{profile: profile} = seed_booking_account("1", "legal-default", "Etc/UTC")

    {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

    assert has_element?(view, "#{@footer} a[href='#{@default_privacy}']", "Privacy policy")
    refute has_element?(view, "#{@footer} a", "Legal notice")
  end

  test "a payment page's dead render has no footer; the connected one has the organiser's links",
       %{conn: conn} do
    %{user: user, profile: profile} = seed_booking_account("1", "legal-payment", "Etc/UTC")

    {:ok, _profile} =
      Profiles.update_legal_links(profile, %{
        "legal_notice_url" => "https://example.com/imprint",
        "privacy_policy_url" => "https://example.com/privacy"
      })

    meeting = insert(:meeting, organizer_user_id: user.id, status: :awaiting_payment)
    path = "/themes/quill/payment-cancelled/#{meeting.id}"

    dead = conn |> get(path) |> html_response(200)

    assert dead =~ "data-booker-root"
    refute dead =~ ~s(data-testid="legal-links")
    refute dead =~ @default_privacy

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#{@footer} a[href='https://example.com/imprint']", "Legal notice")

    assert has_element?(
             view,
             "#{@footer} a[href='https://example.com/privacy']",
             "Privacy policy"
           )

    refute has_element?(view, "#{@footer} a[href='#{@default_privacy}']")
  end
end
