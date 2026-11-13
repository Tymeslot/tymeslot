defmodule TymeslotWeb.Themes.Shared.EmbedLocaleSwitchTest do
  @moduledoc """
  An embedded booking page must stay embedded when the visitor changes
  language.

  The switcher issues a full redirect inside the iframe. The page that comes
  back knows only what that URL carries, so the redirect has to rebuild the
  embed: the flag that earns the embed token, the parent origin the token is
  checked against, and the theme, layout and accent colour the embedder chose.
  It must do that without re-creating #84, where carrying `theme=` turned
  every visitor into a previewer and failed their booking closed.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :themes
  @moduletag :bookings
  @moduletag :i18n
  @moduletag :integration

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Ecto.Changeset
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  @parent_origin "https://embedder.test"
  @colour "#e11d48"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)

    TestMocks.setup_email_mocks()
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    timezone = "America/New_York"
    # The organiser's saved theme is Quill; the embed asks for Rhythm, so a
    # redirect that dropped `theme=` would visibly fall back.
    %{user: user, profile: profile} = seed_booking_account("1", "embed-locale", timezone)

    profile
    |> Changeset.change(allowed_embed_domains: ["embedder.test"])
    |> Repo.update!()

    %{user: user, profile: profile, timezone: timezone}
  end

  @tag :capture_log
  test "a language switch keeps the embed, its theme, layout and colour, and the booking still persists",
       %{conn: conn, user: user, profile: profile, timezone: timezone} do
    query =
      URI.encode_query(%{
        "embed" => "1",
        "parent-origin" => @parent_origin,
        "theme" => "2",
        "layout" => "column",
        "primary-color" => @colour,
        "timezone" => timezone
      })

    {:ok, view, _html} = live(conn, "/#{profile.username}?#{query}")

    path = switch_language(view, "de")
    params = path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert params["embed"] == "1"
    assert params["parent-origin"] == @parent_origin
    assert params["theme"] == "2"
    assert params["layout"] == "column"
    assert params["primary-color"] == @colour
    refute Map.has_key?(params, "preview")
    refute Map.has_key?(params, "preview_token")

    # Follow the redirect as the iframe does: the browser now names the booking
    # page itself as the Referer, which must not replace the embedder's origin.
    conn =
      conn
      |> recycle()
      |> put_req_header("referer", "http://#{conn.host}/#{profile.username}?#{query}")
      |> get(path)

    html = html_response(conn, 200)
    document = Floki.parse_document!(html)
    [root_class] = Floki.attribute(document, "html", "class")

    assert root_class =~ "rhythm-theme"
    assert Floki.attribute(document, "html", "data-embed-layout") == ["column"]
    assert Floki.attribute(document, "html", "lang") == ["de"]
    assert html =~ "--theme-primary: #{@colour}"

    # The connected mount re-verifies the embed token against the allowlist;
    # a rejected one redirects to /embed-unavailable instead of mounting.
    {:ok, view, _html} = live(conn)

    attendee_email = "embed-locale@example.com"

    confirmation_html =
      BookingDriver.book(view,
        attendee: %{
          name: "Embed Locale Attendee",
          email: attendee_email,
          message: "Booked inside an embed after switching language"
        }
      )

    assert confirmation_html =~ attendee_email

    # A real booking, not a preview simulation: the carried `theme=` is not a
    # preview claim.
    meeting =
      Repo.get_by!(MeetingSchema, organizer_user_id: user.id, attendee_email: attendee_email)

    assert meeting.status == :confirmed

    # Still embedded after the switch: the page kept its verified embed, so the
    # next switch (here from the confirmation step) rebuilds it again.
    assert switch_language(view, "en") =~ "embed=1"
  end

  # The iframe gets no session (the browser withholds the cookie cross-site),
  # so only the URL can carry the language: on the switcher's redirect and on
  # every step's own patch, which a reconnect remounts from.
  test "a language switch inside an embed offering some languages keeps the translated texts through the steps",
       %{conn: conn, user: user, profile: profile, timezone: timezone} do
    profile
    |> Changeset.change(
      content_locale: "en",
      translation_locales: ["de"],
      offer_all_locales: false
    )
    |> Repo.update!()

    MeetingTypeSchema
    |> Repo.get_by!(user_id: user.id)
    |> Changeset.change(
      translations: %{
        "de" => %{
          "name" => %{"text" => "Kurzes Gespräch", "source" => :erlang.phash2("Quick Chat")}
        }
      }
    )
    |> Repo.update!()

    query =
      URI.encode_query(%{
        "embed" => "1",
        "parent-origin" => @parent_origin,
        "timezone" => timezone
      })

    {:ok, view, _html} = live(conn, "/#{profile.username}?#{query}")
    assert render(view) =~ "Quick Chat"

    path = switch_language(view, "de")
    assert URI.decode_query(URI.parse(path).query)["locale"] == "de"

    {:ok, view, _html} = live(build_conn(), path)
    html = render(view)
    assert html =~ ~s(data-locale="de")
    assert html =~ "Kurzes Gespräch"
    refute html =~ "Quick Chat"

    BookingDriver.book(view, until: :attendee)
    assert has_element?(view, "form[data-fact='attendee']")
    html = render(view)
    assert html =~ ~s(data-locale="de")
    assert html =~ "Kurzes Gespräch"

    step_url = last_patch(view)
    step_query = URI.decode_query(URI.parse(step_url).query)
    assert step_query["locale"] == "de"
    assert step_query["embed"] == "1"

    {:ok, remounted, _html} = live(build_conn(), step_url)
    html = render(remounted)
    assert html =~ ~s(data-locale="de")
    assert html =~ "Kurzes Gespräch"
    refute html =~ "Quick Chat"
  end

  # The URL the page's own patches left it on.
  defp last_patch(view, last \\ nil) do
    last_patch(view, assert_patch(view, 100))
  rescue
    _no_more_patches in [ArgumentError, ExUnit.AssertionError] ->
      last || flunk("the page never patched its URL")
  end

  # Drives the real language switcher and returns the path of the full
  # redirect it issues.
  defp switch_language(view, locale) do
    view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

    assert {:error, {:redirect, %{to: path}}} =
             view
             |> element("button[phx-click='change_locale'][phx-value-locale='#{locale}']")
             |> render_click()

    path
  end
end
