defmodule TymeslotWeb.Dashboard.EmbedMeetingTypesTest do
  @moduledoc """
  Embed & Share opens a snippet or link on one meeting type, at the one
  address the type is booked at, and lets the direct link carry a visitor's
  name and email.
  """
  use TymeslotWeb.LiveCase, async: true

  @moduletag :dashboard
  @moduletag :embed

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Repo

  setup :setup_dashboard_user_with_theme

  setup %{profile: profile} do
    %{profile: profile |> Changeset.change(username: "joern") |> Repo.update!()}
  end

  defp choose_type(view, type),
    do:
      view |> form("#embed-meeting-type-picker") |> render_change(%{"type" => to_string(type.id)})

  # The address the inline snippet's frame opens, as embed.js builds it: the
  # snippet's `data-username`, then its `data-meeting-type` as one more segment.
  defp inline_address(html) do
    [_match, address] = Regex.run(~r/data-username=(?:&quot;|")([^&"]+)/, html)

    case Regex.run(~r/data-meeting-type=(?:&quot;|")([^&"]+)/, html) do
      [_match, slug] -> address <> "/" <> slug
      nil -> address
    end
  end

  describe "the meeting type picker" do
    test "without bookable types there is no picker", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/embed")

      refute has_element?(view, "#embed-meeting-type-picker")
    end

    test "starts on the overview, which keeps the page's address", %{conn: conn, user: user} do
      insert(:meeting_type, user: user, name: "Intro", slug: "intro")
      {:ok, view, html} = live(conn, ~p"/dashboard/embed")

      assert has_element?(view, "#embed-meeting-type-select option[value='overview'][selected]")
      assert inline_address(html) == "joern"
    end

    test "a type on the profile's page opens at its own address", %{conn: conn, user: user} do
      type = insert(:meeting_type, user: user, name: "Intro", slug: "ux")
      {:ok, view, _html} = live(conn, ~p"/dashboard/embed")

      html = choose_type(view, type)

      # A two-letter slug, shorter than any username may be, still passes.
      assert inline_address(html) == "joern/ux"
      assert html =~ "data-username=&quot;joern&quot; data-meeting-type=&quot;ux&quot;"
      assert html =~ "TymeslotBooking.open(&#39;joern&#39;, {meetingType: &#39;ux&#39;"
      assert html =~ "TymeslotBooking.initFloating(&#39;joern&#39;, {meetingType: &#39;ux&#39;"
      assert html =~ ~r{href=&quot;[^&]*/joern/ux\?layout=column&quot;}
      assert_patch(view, ~p"/dashboard/embed?#{[type: type.id]}")
    end

    test "an unlisted type opens under the page that lists it, and the page follows", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      page = insert(:booking_page, profile: profile, slug: "coaching", name: "Coaching")

      type =
        insert(:meeting_type, user: user, name: "Deep dive", slug: "deep-dive", is_private: true)

      insert(:booking_page_meeting_type, booking_page: page, meeting_type: type)

      {:ok, view, _html} = live(conn, ~p"/dashboard/embed")

      assert has_element?(
               view,
               "#embed-meeting-type-select optgroup[label='Coaching · /joern/coaching'] option[value='#{type.id}']",
               "Deep dive (unlisted)"
             )

      html = choose_type(view, type)

      assert inline_address(html) == "joern/coaching/deep-dive"
      assert has_element?(view, "#embed-page-select option[value='#{page.id}'][selected]")
      assert has_element?(view, "#embed-private-type-note", "anyone with this snippet or link")
    end

    test "a public type listed on a page too keeps the profile's address", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      page = insert(:booking_page, profile: profile, slug: "coaching")
      type = insert(:meeting_type, user: user, name: "Intro", slug: "intro")
      insert(:booking_page_meeting_type, booking_page: page, meeting_type: type)

      {:ok, view, _html} = live(conn, ~p"/dashboard/embed")
      html = choose_type(view, type)

      assert inline_address(html) == "joern/intro"
      assert has_element?(view, "#embed-page-select option[value='profile'][selected]")
      refute has_element?(view, "#embed-private-type-note")
    end

    test "an invitation-only type is not offered, and the help line says why", %{
      conn: conn,
      user: user
    } do
      insert(:meeting_type, user: user, name: "Intro", slug: "intro")

      invited =
        insert(:meeting_type, user: user, name: "Board", slug: "board", invitation_only: true)

      {:ok, view, _html} = live(conn, ~p"/dashboard/embed")

      refute has_element?(view, "#embed-meeting-type-select option[value='#{invited.id}']")
      assert has_element?(view, "#embed-meeting-type-picker", "shared from their invitations")

      # Nor can it be reached by its id in the URL.
      {:ok, _view, html} = live(conn, ~p"/dashboard/embed?#{[type: invited.id]}")
      assert inline_address(html) == "joern"
    end

    test "the help line stays away without invitation-only types", %{conn: conn, user: user} do
      insert(:meeting_type, user: user, name: "Intro", slug: "intro")
      {:ok, view, _html} = live(conn, ~p"/dashboard/embed")

      refute has_element?(view, "#embed-meeting-type-picker", "shared from their invitations")
    end

    test "choosing a page goes back to that page's overview", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      page = insert(:booking_page, profile: profile, slug: "coaching")
      type = insert(:meeting_type, user: user, name: "Intro", slug: "intro")
      {:ok, view, _html} = live(conn, ~p"/dashboard/embed")

      choose_type(view, type)
      html = view |> form("#embed-page-picker") |> render_change(%{"page" => to_string(page.id)})

      assert inline_address(html) == "joern/coaching"
      assert has_element?(view, "#embed-meeting-type-select option[value='overview'][selected]")
    end

    test "the overview again keeps the type's page", %{conn: conn, user: user, profile: profile} do
      page = insert(:booking_page, profile: profile, slug: "coaching")
      type = insert(:meeting_type, user: user, name: "Deep dive", slug: "deep", is_private: true)
      insert(:booking_page_meeting_type, booking_page: page, meeting_type: type)
      {:ok, view, _html} = live(conn, ~p"/dashboard/embed")

      choose_type(view, type)

      html =
        view |> form("#embed-meeting-type-picker") |> render_change(%{"type" => "overview"})

      assert inline_address(html) == "joern/coaching"
    end

    test "a type id the profile does not have changes nothing", %{conn: conn, user: user} do
      insert(:meeting_type, user: user, name: "Intro", slug: "intro")
      other = insert(:meeting_type, name: "Not mine", slug: "not-mine")
      {:ok, view, _html} = live(conn, ~p"/dashboard/embed")

      html =
        view
        |> element("#embed-meeting-type-picker")
        |> render_change(%{"type" => to_string(other.id)})

      assert inline_address(html) == "joern"
    end

    test "a reload keeps the chosen type", %{conn: conn, user: user} do
      type = insert(:meeting_type, user: user, name: "Intro", slug: "intro")

      {:ok, view, html} = live(conn, ~p"/dashboard/embed?#{[type: type.id]}")

      assert inline_address(html) == "joern/intro"
      assert has_element?(view, "#embed-meeting-type-select option[value='#{type.id}'][selected]")
    end
  end

  describe "the direct link's visitor details" do
    test "carry a name and email in the link's fragment", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/embed")

      html =
        view
        |> form("#embed-link-prefill-form")
        |> render_change(%{"prefill" => %{"name" => "Ann Lee", "email" => "ann+crm@example.com"}})

      assert html =~ "/joern?layout=column#name=Ann%20Lee&amp;email=ann%2Bcrm%40example.com&quot;"
      refute html =~ "embed-prefill-email-error"
    end

    test "leave out an address the booking form would refuse, and say so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/embed")

      html =
        view
        |> form("#embed-link-prefill-form")
        |> render_change(%{"prefill" => %{"name" => "Ann Lee", "email" => "not-an-address"}})

      assert html =~ "/joern?layout=column#name=Ann%20Lee&quot;"
      refute html =~ "not-an-address&quot;"
      assert has_element?(view, "#embed-link-prefill-form", "would not accept this")
    end

    test "stay out of the embed snippets", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/embed")

      html =
        view
        |> form("#embed-link-prefill-form")
        |> render_change(%{"prefill" => %{"name" => "Ann Lee", "email" => "ann@example.com"}})

      assert [_only_the_link] = Regex.scan(~r/#name=/, html)
      assert inline_address(html) == "joern"
    end

    test "copying the link copies the details with it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/embed")

      view
      |> form("#embed-link-prefill-form")
      |> render_change(%{"prefill" => %{"name" => "Ann", "email" => "ann@example.com"}})

      view |> element("button[phx-value-type='link']", "Copy") |> render_click()

      assert_push_event(view, "copy-to-clipboard", %{text: text})
      assert text =~ ~s(/joern?layout=column#name=Ann&email=ann%40example.com">)
    end
  end
end
