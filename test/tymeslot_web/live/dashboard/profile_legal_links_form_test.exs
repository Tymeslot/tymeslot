defmodule TymeslotWeb.Dashboard.ProfileLegalLinksFormTest do
  @moduledoc """
  The organiser's legal notice and privacy policy links, from the "Legal
  links" form in Profile Settings: both fields present, saved with the
  button, flagged while typed when invalid, refused when unsafe, showing the
  instance default while blank, and restored when the page is opened again.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :profiles
  @moduletag :integration

  import Mox
  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Ecto.Changeset
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  setup %{conn: conn} do
    %{user: user, profile: profile} = seed_booking_account("4", "legal-organiser", "UTC")

    user =
      user
      |> Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
      |> Repo.update!()

    conn = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    %{conn: conn, profile: profile}
  end

  defp open_settings(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/settings")
    view
  end

  defp stored(profile) do
    profile = Repo.reload!(profile)
    {profile.legal_notice_url, profile.privacy_policy_url}
  end

  describe "the form" do
    test "sits in Profile Settings with both fields", %{conn: conn} do
      view = open_settings(conn)

      assert has_element?(view, "#legal-links-form")

      assert has_element?(
               view,
               "#legal-links-form input[type='url'][name='profile_legal_links[legal_notice_url]']"
             )

      assert has_element?(
               view,
               "#legal-links-form input[type='url'][name='profile_legal_links[privacy_policy_url]']"
             )

      assert render(view) =~ "Legal links"
    end

    test "saves both links", %{conn: conn, profile: profile} do
      view = open_settings(conn)

      view
      |> form("#legal-links-form",
        profile_legal_links: %{
          legal_notice_url: "https://example.com/imprint",
          privacy_policy_url: "https://example.com/privacy"
        }
      )
      |> render_submit()

      assert render(view) =~ "Legal links saved"

      assert stored(profile) ==
               {"https://example.com/imprint", "https://example.com/privacy"}
    end

    test "flags an http link to a public host while typed, and saves nothing", %{
      conn: conn,
      profile: profile
    } do
      view = open_settings(conn)

      html =
        view
        |> form("#legal-links-form",
          profile_legal_links: %{privacy_policy_url: "http://example.com/privacy"}
        )
        |> render_change()

      assert html =~ "Use HTTPS for non-local servers"
      assert has_element?(view, "#legal-links-form [role='alert']")
      assert stored(profile) == {nil, nil}
    end

    test "refuses a javascript: URL", %{conn: conn, profile: profile} do
      view = open_settings(conn)

      html =
        view
        |> form("#legal-links-form",
          profile_legal_links: %{legal_notice_url: "javascript:alert(1)"}
        )
        |> render_submit()

      refute html =~ "Legal links saved"
      assert render(view) =~ "save your legal links"
      assert has_element?(view, "#legal-links-form [role='alert']")
      assert stored(profile) == {nil, nil}
    end

    test "shows the instance default when the field is blank", %{conn: conn, profile: profile} do
      previous = Application.get_env(:tymeslot, :booking_privacy_policy_url)
      Application.put_env(:tymeslot, :booking_privacy_policy_url, "https://host.example/privacy")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:tymeslot, :booking_privacy_policy_url, previous),
          else: Application.delete_env(:tymeslot, :booking_privacy_policy_url)
      end)

      view = open_settings(conn)

      assert has_element?(
               view,
               "#legal-links-form input[name='profile_legal_links[privacy_policy_url]'][placeholder='https://host.example/privacy']"
             )

      assert render(view) =~ "Instance default in use: https://host.example/privacy"

      view
      |> form("#legal-links-form",
        profile_legal_links: %{privacy_policy_url: "https://example.com/privacy"}
      )
      |> render_submit()

      refute render(view) =~ "Instance default in use"
      assert stored(profile) == {nil, "https://example.com/privacy"}
    end

    test "shows what is saved when the page is opened again", %{conn: conn, profile: profile} do
      {:ok, _saved} =
        Profiles.update_legal_links(profile, %{
          "legal_notice_url" => "https://example.com/imprint",
          "privacy_policy_url" => "https://example.com/privacy"
        })

      view = open_settings(conn)

      assert has_element?(
               view,
               "#legal-links-form input[name='profile_legal_links[legal_notice_url]'][value='https://example.com/imprint']"
             )

      assert has_element?(
               view,
               "#legal-links-form input[name='profile_legal_links[privacy_policy_url]'][value='https://example.com/privacy']"
             )
    end
  end
end
