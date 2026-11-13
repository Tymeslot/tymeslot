defmodule TymeslotWeb.Dashboard.LanguagesBookingPageTest do
  @moduledoc """
  From the dashboard to the visitor: a meeting type name translated on the
  Languages review page, and a heading translated from the booking text
  card's language bar, show on the public booking page in that language, for
  an organiser who offers only English and German. An outdated name shows in
  the original until it is kept as still correct.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :i18n

  import Mox
  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.ContentTranslations.Catalogue
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())

    profile =
      insert(:profile,
        user: user,
        username: "lingo-dash",
        booking_theme: "1",
        content_locale: "en",
        translation_locales: ["de"],
        offer_all_locales: false
      )

    insert(:calendar_integration, user: user, is_active: true)
    meeting_type = insert(:meeting_type, user: user, name: "Intro call", duration_minutes: 30)

    %{user: user, profile: profile, meeting_type: meeting_type}
  end

  test "a name translated on the review page shows on the German booking page", %{
    conn: conn,
    user: user,
    profile: profile,
    meeting_type: meeting_type
  } do
    dashboard = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, view, _html} = live(dashboard, ~p"/dashboard/languages/de")

    view
    |> form("#translation-meeting_types-meeting_type-#{meeting_type.id}-form", %{
      "translation" => %{"name" => "Erstgespräch"}
    })
    |> render_submit()

    {:ok, page, _html} = live(build_conn(), "/#{profile.username}?locale=de")
    html = render(page)
    assert html =~ ~s(data-locale="de")
    assert html =~ "Erstgespräch"
    refute html =~ "Intro call"

    {:ok, original, _html} = live(build_conn(), "/#{profile.username}?locale=en")
    assert render(original) =~ "Intro call"
  end

  test "an outdated name shows in the original until it is kept as still correct", %{
    conn: conn,
    user: user,
    profile: profile,
    meeting_type: meeting_type
  } do
    {:ok, _entity} =
      Catalogue.save(user.id, {:meeting_type, meeting_type.id}, "de", %{"name" => "Gespräch"})

    meeting_type |> Changeset.change(name: "First call") |> Repo.update!()

    {:ok, page, _html} = live(build_conn(), "/#{profile.username}?locale=de")
    html = render(page)
    assert html =~ "First call"
    refute html =~ "Gespräch"

    dashboard = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, view, _html} = live(dashboard, ~p"/dashboard/languages/de")

    view
    |> element(
      "#translation-meeting_types-meeting_type-#{meeting_type.id} [data-path='name'] [data-testid='confirm-translation']"
    )
    |> render_click()

    {:ok, page, _html} = live(build_conn(), "/#{profile.username}?locale=de")
    html = render(page)
    assert html =~ "Gespräch"
    refute html =~ "First call"
  end

  test "a heading translated from the booking text card shows on the German booking page", %{
    conn: conn,
    user: user,
    profile: profile
  } do
    profile
    |> Changeset.change(
      booking_text_enabled: true,
      booking_heading: "Ready to talk?",
      booking_greeting: "I am Lingo.",
      booking_instruction: "Pick a time."
    )
    |> Repo.update!()

    dashboard = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, view, _html} = live(dashboard, ~p"/dashboard/pages")
    card = "#booking-text-form-translations"

    view |> element("#{card}-bar-de") |> render_click()

    view
    |> form("#{card}-editor-form", %{"translation" => %{"booking_heading" => "Bereit zu reden?"}})
    |> render_submit()

    {:ok, page, _html} = live(build_conn(), "/#{profile.username}?locale=de")
    html = render(page)
    assert html =~ "Bereit zu reden?"
    refute html =~ "Ready to talk?"

    {:ok, original, _html} = live(build_conn(), "/#{profile.username}?locale=en")
    assert render(original) =~ "Ready to talk?"
  end
end
