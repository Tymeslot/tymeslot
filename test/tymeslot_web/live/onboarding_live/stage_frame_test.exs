defmodule TymeslotWeb.OnboardingLive.StageFrameTest do
  @moduledoc """
  The onboarding layout around every step: the question column with its
  progress and live region, and the stage that shows the host's booking page
  in a browser frame beside (or, on a phone, above) it.
  """

  use TymeslotWeb.LiveCase, async: true
  @moduletag :onboarding

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Tymeslot.Factory, only: [insert: 2]
  import TymeslotWeb.OnboardingTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.Utils.UrlBuilder

  setup tags do
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  # Walks a host with a bookable calendar through all five steps, returning
  # each step with the page as it rendered there.
  defp walk_steps(conn) do
    {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
    # The week the calendar unlocks, read as the wizard mounts.
    render_async(view)

    profile = render(view)
    fill_profile(view, "Anna Example", "anna#{System.unique_integer([:positive])}")

    rest =
      for step <- [:connect_calendar, :meeting, :choose_theme, :ready] do
        click_continue(view)
        {step, render(view)}
      end

    [{:profile, profile} | rest]
  end

  defp find(html, selector), do: html |> Floki.parse_document!() |> Floki.find(selector)

  defp host, do: String.replace(UrlBuilder.base_url(), ~r{^https?://}, "")

  defp address(view) do
    view |> element(~s([data-role="stage-address"])) |> render() |> Floki.parse_fragment!()
  end

  test "the stage renders on every step", %{conn: conn} do
    steps = walk_steps(conn)

    assert Enum.map(steps, &elem(&1, 0)) == [
             :profile,
             :connect_calendar,
             :meeting,
             :choose_theme,
             :ready
           ]

    assert Enum.reject(steps, fn {_step, html} ->
             find(html, ~s([data-role="onboarding-stage"])) != []
           end) == []
  end

  test "progress shows step N of 5", %{conn: conn} do
    labels =
      for {_step, html} <- walk_steps(conn) do
        html |> find(~s([data-role="onboarding-step-label"])) |> Floki.text() |> String.trim()
      end

    assert labels == Enum.map(1..5, &"Step #{&1} of 5")
  end

  describe "the address pill" do
    test "shows the username as it is typed", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      fill_profile(view, "Anna Example", "anna")

      text = view |> address() |> Floki.text() |> String.trim()

      assert String.ends_with?(text, "#{host()}/anna")
    end

    test "starts on the suggested link", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn, %{name: "Anna Kowalska"})

      text = view |> address() |> Floki.text() |> String.trim()

      assert String.ends_with?(text, "#{host()}/anna-kowalska")
    end

    test "shows a placeholder while the link is empty", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      fill_profile(view, "Anna Example", "")

      text = view |> address() |> Floki.text() |> String.trim()

      assert String.ends_with?(text, "#{host()}/your-name")
    end
  end

  test "the live badge only shows on ready", %{conn: conn} do
    with_badge =
      for {step, html} <- walk_steps(conn),
          find(html, ~s([data-role="stage-live-badge"])) != [],
          do: step

    assert with_badge == [:ready]
  end

  test "a page that is not live gets no live badge or caption on ready", %{conn: conn} do
    {:ok, view, _html, user} = setup_onboarding_with_calendar(conn)
    view = navigate_to_theme_step(view)

    # The calendar stops being bookable before the last step, which checks
    # again on the way in.
    Repo.update_all(
      from(i in CalendarIntegrationSchema, where: i.user_id == ^user.id),
      set: [is_active: false]
    )

    html = view |> click_continue() |> render()

    # Not live, so it says so: no "You're live", no badge, no caption
    # claiming the address is live, and one way to fix it.
    title = html |> find(".onboarding-step-title") |> Floki.text()
    assert title =~ "Almost live"
    refute title =~ "You're live"
    assert find(html, ~s([data-role="stage-live-badge"])) == []
    assert find(html, ".onboarding-stage-caption") == []
    refute html =~ "is live"

    assert [_fix] =
             find(html, "#onboarding-page-offline-warning button#onboarding-return-to-calendar")
  end

  test "the caption tells the week on the calendar and meeting steps, and the address on ready",
       %{conn: conn} do
    captions =
      for {step, html} <- walk_steps(conn),
          find(html, ".onboarding-stage-caption") != [],
          do: step

    assert captions == [:connect_calendar, :meeting, :ready]
  end

  test "the layout has one polite live region and the stage is aria-hidden", %{conn: conn} do
    {:ok, view, _html, _user} = setup_onboarding(conn)
    html = render(view)

    assert [region] = find(html, ~s([aria-live="polite"]))
    assert Floki.attribute(region, "data-role") == ["stage-announcement"]

    assert find(
             html,
             ~s([data-role="onboarding-stage"] [aria-hidden="true"] [data-role="stage-miniature"])
           ) !=
             []
  end

  test "the stage takes the chosen theme's canvas colour", %{conn: conn} do
    {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
    view = navigate_to_theme_step(view)

    html = view |> element("button[phx-value-theme='3']") |> render_click()

    canvas = ThemeCustomizations.tokens("3", nil).vars["--theme-canvas"]
    assert canvas =~ ~r/^#[0-9a-f]{6}$/i
    # Paper's light canvas, not the dark one the page opened with.
    refute canvas == ThemeCustomizations.tokens("1", nil).vars["--theme-canvas"]

    assert [style] = html |> find(~s([data-role="onboarding-stage"])) |> Floki.attribute("style")
    assert style =~ "--stage-canvas: #{canvas}"
  end

  describe "the heading focus" do
    test "is left alone on the first load and taken on a step change", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)

      refute has_element?(view, "#onboarding-step-heading-profile[phx-mounted]")

      fill_profile(view, "Anna Example", "anna#{System.unique_integer([:positive])}")
      click_continue(view)

      [mounted] =
        view
        |> render()
        |> find("#onboarding-step-heading-connect_calendar")
        |> Floki.attribute("phx-mounted")

      assert mounted =~ "focus"
    end
  end

  describe "the expanded preview" do
    test "opens from the stage and closes again", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      refute has_element?(view, ~s(#onboarding-stage-preview [data-role="stage-miniature"]))

      view |> element(~s(button[phx-click="expand_stage"])) |> render_click()

      assert has_element?(view, ~s(#onboarding-stage-preview [data-role="stage-miniature"]))

      view
      |> element("#onboarding-stage-preview button[aria-label='Close modal']")
      |> render_click()

      refute has_element?(view, ~s(#onboarding-stage-preview [data-role="stage-miniature"]))
    end
  end

  describe "the week on the stage" do
    test "the caption reaches the live region and shows under the stage", %{conn: conn} do
      # The helper's calendar answers with a free week, so the host's own
      # hours decide the slots.
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
      render_async(view)
      navigate_to_calendar_step(view)

      doc = view |> render() |> Floki.parse_document!()

      assert [region] = Floki.find(doc, ~s([data-role="stage-announcement"]))
      assert Floki.attribute(region, "aria-live") == ["polite"]
      announced = region |> Floki.text() |> String.trim()
      assert announced =~ ~r/^\d+ open slots this week\.$/

      assert [caption] = Floki.find(doc, ".onboarding-stage-caption")
      assert String.trim(Floki.text(caption)) == announced

      # The times are on the page, in the new list the bumped key reveals.
      assert Floki.find(doc, ~s(#stage-times-1 [data-reveal-item])) != []
    end
  end

  describe "the first paint" do
    # A host with a username, a live page and a chosen theme, seen in the
    # static render, before the socket connects.
    defp first_paint(conn, path) do
      {conn, user} = onboarding_conn(conn)
      user = Repo.update!(Changeset.change(user, name: "Ada Lovelace"))
      insert(:calendar_integration, user: user)

      insert(:profile,
        user: user,
        username: "ada-paints",
        full_name: "Ada Lovelace",
        booking_theme: "3"
      )

      conn |> get(path) |> html_response(200)
    end

    test "is the host's own page, not a skeleton", %{conn: conn} do
      html = first_paint(conn, "/onboarding/connect_calendar")

      assert html =~ "Ada Lovelace"
      assert Floki.text(find(html, ~s([data-role="preview-address-name"]))) =~ "ada-paints"
      refute html =~ "your-name"

      # Drawn on the chosen theme's canvas from the start, under the one id
      # the connected render keeps.
      canvas = ThemeCustomizations.tokens("3", nil).vars["--theme-canvas"]
      assert [stage] = find(html, ~s(#onboarding-stage[data-role="onboarding-stage"]))
      assert [style] = Floki.attribute(stage, "style")
      assert style =~ "--stage-canvas: #{canvas}"
    end

    test "names the real address as live on the last step", %{conn: conn} do
      html = first_paint(conn, "/onboarding/ready")

      assert [caption] = find(html, ".onboarding-stage-caption")
      assert Floki.text(caption) =~ "/ada-paints is live"
      refute html =~ "your-name"
    end
  end
end
