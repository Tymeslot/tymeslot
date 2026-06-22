defmodule TymeslotWeb.SchedulingOgMetaTest do
  @moduledoc """
  Verifies the Open Graph / Twitter social-share meta tags rendered into the
  scheduling root layout when a booking link is shared.
  """
  use TymeslotWeb.ConnCase, async: false
  @moduletag :seo

  import Tymeslot.Factory
  import Mox

  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Layouts

  setup do
    user = insert(:user, name: "Ada Lovelace")
    profile = insert(:profile, user: user, username: "ada")

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _integration, _start, _stop ->
      {:ok, []}
    end)

    insert(:calendar_integration, user: user, provider: "google", is_active: true)
    insert(:meeting_type, user: user, name: "Intro Call", duration_minutes: 30, is_active: true)

    {:ok, user: user, profile: profile, username: profile.username}
  end

  describe "organiser booking page" do
    test "uses the neutral default avatar when no photo is uploaded", %{
      conn: conn,
      username: username
    } do
      html = conn |> get(~p"/#{username}") |> html_response(200)

      assert html =~ ~s(<meta property="og:image" content=")
      assert html =~ "/images/brand/default-avatar.png"
      assert html =~ ~s(<meta name="twitter:card" content="summary")
      # Square avatar pairs with the `summary` card, not the wide variant.
      refute html =~ ~s(content="summary_large_image")
      # Never expose the in-app initials data URI to social scrapers.
      refute html =~ ~s(property="og:image" content="data:image/svg)
    end

    test "uses the uploaded profile photo as the share image", %{conn: conn} do
      profile = insert(:profile, user: build(:user), username: "grace", avatar: "grace.png")

      html = conn |> get(~p"/#{profile.username}") |> html_response(200)

      assert html =~ "/uploads/avatars/#{profile.id}/grace.png"
      refute html =~ "/images/brand/default-avatar.png"
    end

    test "renders a personalised title and description", %{conn: conn, username: username} do
      html = conn |> get(~p"/#{username}") |> html_response(200)

      assert html =~ ~s(<meta property="og:title" content="Schedule with Ada Lovelace")
      assert html =~ "Book a meeting with Ada Lovelace."
      assert html =~ ~s(<meta property="og:type" content="profile")
      assert html =~ ~s(<meta property="og:site_name" content="Tymeslot")
    end

    test "builds an absolute og:url for the booking page", %{conn: conn, username: username} do
      html = conn |> get(~p"/#{username}") |> html_response(200)

      assert html =~ ~s(<meta property="og:url" content="#{Endpoint.url()}/#{username}")
    end

    test "localises title and description for the request locale", %{
      conn: conn,
      username: username
    } do
      html = conn |> get(~p"/#{username}?locale=de") |> html_response(200)

      # Title (shared with the browser tab) and description both follow the locale.
      assert html =~ ~s(<meta property="og:title" content="Termin mit Ada Lovelace")
      assert html =~ "Vereinbaren Sie einen Termin mit Ada Lovelace."
    end
  end

  describe "defensive fallback (no organiser context)" do
    test "og image falls back to the Tymeslot brand card" do
      assert Layouts.booking_og_image(%{}) =~ "/images/brand/og-image.png"
    end

    test "twitter card uses the wide variant for the brand card" do
      assert Layouts.booking_twitter_card(%{}) == "summary_large_image"
    end

    test "description falls back to a generic prompt" do
      assert Layouts.booking_og_description(%{}) =~ "Pick a time that works for you"
    end
  end
end
