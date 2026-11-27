defmodule TymeslotWeb.Integration.EmbedMeetingTypeSnippetTest do
  @moduledoc """
  A snippet generated in Embed & Share for one meeting type opens, embedded,
  straight on that type's scheduling step, and an embed that hands over a
  visitor's details opens the booking form with them filled in.

  The iframe address is built from the copied snippet's `data-username` and
  `data-meeting-type` the way `embed.js` builds it (the type's slug as one
  more segment, then `?embed=1&parent-origin=`), and a snippet written by
  hand may name the type under the username alone; the name and email
  `embed.js` puts in the iframe's fragment reach the LiveView as its
  `attendee_prefill` connect params, which is what the browser sends.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :embed
  @moduletag :scheduling

  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.BookingTestHelpers
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver.Page

  @timezone "Etc/UTC"
  @iframe_query "embed=1&parent-origin=https%3A%2F%2Fembedder.test&layout=column&timezone=#{@timezone}"

  setup do
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    %{user: user, profile: profile} =
      BookingTestHelpers.seed_booking_account("1", "snippethost", @timezone)

    user |> Changeset.change(onboarding_completed_at: DateTime.utc_now(:second)) |> Repo.update!()

    profile =
      profile |> Changeset.change(allowed_embed_domains: ["embedder.test"]) |> Repo.update!()

    page = insert(:booking_page, profile: profile, slug: "coaching", booking_theme: "1")

    type =
      insert(:meeting_type,
        user: user,
        name: "Deep dive",
        slug: "deep-dive",
        duration_minutes: 30,
        is_private: true
      )

    insert(:booking_page_meeting_type, booking_page: page, meeting_type: type)

    %{user: user, type: type}
  end

  defp snippet_target(user, type) do
    owner = build_conn() |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, _view, html} = live(owner, ~p"/dashboard/embed?#{[type: type.id]}")

    [_match, address] = Regex.run(~r/data-username=&quot;([^&]+)&quot;/, html)
    [_match, slug] = Regex.run(~r/data-meeting-type=&quot;([^&]+)&quot;/, html)
    {address, slug}
  end

  defp visitor do
    put_req_header(build_conn(), "referer", "https://embedder.test/page")
  end

  @tag :capture_log
  test "the inline snippet's frame mounts on the type's scheduling step", %{
    user: user,
    type: type
  } do
    assert snippet_target(user, type) == {"snippethost/coaching", "deep-dive"}

    assert {:ok, view, _html} =
             live(visitor(), "/snippethost/coaching/deep-dive?#{@iframe_query}")

    assert Page.assigns(view).embedded == true
    assert has_element?(view, "#schedule-step [data-fact='date']")
    refute has_element?(view, "[data-fact='meeting_type']")
  end

  @tag :capture_log
  test "a type named under the username alone opens embedded under its page" do
    assert {:error, {:redirect, %{to: to}}} =
             live(visitor(), "/snippethost/deep-dive?#{@iframe_query}")

    assert %URI{path: "/snippethost/coaching/deep-dive", query: query} = URI.parse(to)
    assert %{"embed" => "1", "parent-origin" => "https://embedder.test"} = URI.decode_query(query)

    assert {:ok, view, _html} = live(visitor(), to)

    assert Page.assigns(view).embedded == true
    assert has_element?(view, "#schedule-step [data-fact='date']")
  end

  @tag :capture_log
  test "the embedded booking form opens with the visitor's details", %{user: user, type: type} do
    {page_address, slug} = snippet_target(user, type)
    address = page_address <> "/" <> slug

    {:ok, view, _html} =
      visitor()
      |> put_connect_params(%{
        "attendee_prefill" => %{"name" => "Ann Lee", "email" => "ann@example.com"}
      })
      |> live("/#{address}?#{@iframe_query}")

    view = BookingTestHelpers.walk_from_schedule_to_booking_form(view, @timezone)

    assert input_value(view, "#booking-form input[name='booking[name]']") == "Ann Lee"
    assert input_value(view, "#booking-form input[name='booking[email]']") == "ann@example.com"
  end

  defp input_value(view, selector) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.attribute(selector, "value")
    |> List.first()
  end
end
