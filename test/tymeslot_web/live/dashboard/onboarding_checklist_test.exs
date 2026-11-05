defmodule TymeslotWeb.Dashboard.OnboardingChecklistTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :onboarding

  import Phoenix.LiveViewTest

  alias Tymeslot.Onboarding
  alias TymeslotWeb.Dashboard.OnboardingChecklist

  @quill "1"
  @folio "4"

  @no_integrations %{
    has_meeting_types: true,
    has_calendar: false,
    calendar_ready: false,
    has_video: false
  }
  @all_integrations %{
    has_meeting_types: true,
    has_calendar: true,
    calendar_ready: true,
    has_video: true
  }

  defp user(attrs \\ %{}) do
    Map.merge(%{dashboard_setup_done_items: [], dashboard_setup_dismissed_at: nil}, attrs)
  end

  # A host straight out of the setup wizard: no photo, no intro, embedding
  # left at its default, on the default theme.
  defp profile(attrs \\ %{}) do
    Map.merge(
      %{
        username: "alice",
        user_id: 1,
        avatar: nil,
        headline: nil,
        bio: nil,
        booking_theme: @quill,
        allowed_embed_domains: ["none"]
      },
      attrs
    )
  end

  defp render_checklist(opts) do
    render_component(&OnboardingChecklist.onboarding_checklist/1,
      integration_status: Keyword.get(opts, :integration_status, @no_integrations),
      current_user: Keyword.get(opts, :user, user()),
      profile: Keyword.get(opts, :profile, profile())
    )
  end

  defp rows(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-setup-item]")
    |> LazyHTML.attribute("data-setup-item")
  end

  defp has?(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count() > 0
  end

  defp toggle_ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(button[phx-click="onboarding:toggle"]))
    |> LazyHTML.attribute("phx-value-id")
  end

  describe "visible?/3" do
    test "is visible while a setup item is outstanding and the widget is open" do
      assert OnboardingChecklist.visible?(user(), @all_integrations, profile())
    end

    test "is hidden once the host has dismissed the widget" do
      refute OnboardingChecklist.visible?(
               user(%{dashboard_setup_dismissed_at: DateTime.utc_now(:second)}),
               @no_integrations,
               profile()
             )
    end

    test "is hidden once every item is done from real state" do
      done =
        profile(%{avatar: "alice.webp", allowed_embed_domains: ["alice.example"]})

      refute OnboardingChecklist.visible?(user(), @all_integrations, done)
    end

    test "is hidden once the profile items are ticked off by hand" do
      ticked = user(%{dashboard_setup_done_items: ~w(avatar embed)})
      refute OnboardingChecklist.visible?(ticked, @all_integrations, profile())
    end

    test "counts the intro only where the theme shows it" do
      ticked = user(%{dashboard_setup_done_items: ~w(avatar embed)})

      assert OnboardingChecklist.visible?(
               ticked,
               @all_integrations,
               profile(%{booking_theme: @folio})
             )
    end

    # A host whose stored ticks predate the current catalogue: those keys
    # must neither finish the checklist nor crash it.
    test "ignores ticks stored for items the checklist no longer has" do
      old = user(%{dashboard_setup_done_items: ~w(theme meeting_types share)})
      assert OnboardingChecklist.visible?(old, @all_integrations, profile())
    end
  end

  describe "the catalogue" do
    test "offers the calendar, video, photo and website items on a theme without an intro" do
      html = render_checklist([])

      assert rows(html) == ~w(calendar video avatar embed)
      assert html =~ "0/4"
      refute html =~ "Introduce yourself"
    end

    test "adds the intro item where the theme shows the headline and bio" do
      html = render_checklist(profile: profile(%{booking_theme: @folio}))

      assert rows(html) == ~w(calendar video avatar intro embed)
      assert html =~ "0/5"
      assert html =~ "Introduce yourself"
    end

    test "links each outstanding item to where it is done" do
      html = render_checklist(profile: profile(%{booking_theme: @folio}))

      assert has?(
               html,
               ~s([data-setup-item=calendar] a[href="/dashboard/integrations?tab=calendars"])
             )

      assert has?(html, ~s([data-setup-item=video] a[href="/dashboard/integrations?tab=video"]))
      assert has?(html, ~s([data-setup-item=avatar] a[href="/dashboard/settings"]))
      assert has?(html, ~s([data-setup-item=intro] a[href="/dashboard/settings"]))
      assert has?(html, ~s([data-setup-item=embed] a[href="/dashboard/embed"]))
    end

    test "renders a checkbox for exactly the items the context accepts, and none for providers" do
      html = render_checklist(profile: profile(%{booking_theme: @folio}))

      # The widget and the context would otherwise drift apart silently: a
      # checkbox the context refuses does nothing when clicked.
      assert Enum.sort(toggle_ids(html)) == Enum.sort(Onboarding.manual_dashboard_setup_items())
      assert html =~ ~s(phx-click="onboarding:dismiss")
    end

    test "no longer copies the booking link" do
      html = render_checklist(integration_status: @all_integrations)

      refute html =~ "CopyOnClick"
      refute html =~ "booking_link_copied"
    end
  end

  describe "done states" do
    test "a connected calendar completes its item and drops its link" do
      html =
        render_checklist(
          integration_status: %{@no_integrations | has_calendar: true, calendar_ready: true}
        )

      assert html =~ "1/4"
      refute has?(html, "[data-setup-item=calendar] a")
      assert has?(html, "[data-setup-item=video] a")
    end

    test "a profile photo completes the photo item, with no tick to undo" do
      html = render_checklist(profile: profile(%{avatar: "alice.webp"}))

      assert html =~ "1/4"
      refute has?(html, "[data-setup-item=avatar] a")
      refute "avatar" in toggle_ids(html)
    end

    for {field, value} <- [headline: "Career coach", bio: "I help people change jobs."] do
      test "a #{field} alone completes the intro item" do
        html =
          render_checklist(
            profile: profile(%{:booking_theme => @folio, unquote(field) => unquote(value)})
          )

        assert html =~ "1/5"
        refute has?(html, "[data-setup-item=intro] a")
        refute "intro" in toggle_ids(html)
      end
    end

    test "an allowed embedding site completes the website item" do
      html = render_checklist(profile: profile(%{allowed_embed_domains: ["alice.example"]}))

      assert html =~ "1/4"
      refute has?(html, "[data-setup-item=embed] a")
      refute "embed" in toggle_ids(html)
    end

    test "embedding switched off again leaves the website item open" do
      html = render_checklist(profile: profile(%{allowed_embed_domains: []}))

      assert html =~ "0/4"
      assert has?(html, ~s([data-setup-item=embed] a[href="/dashboard/embed"]))
    end

    test "an item the host ticked off by hand is greyed out and can be unticked" do
      html = render_checklist(user: user(%{dashboard_setup_done_items: ["embed"]}))

      assert html =~ "1/4"
      refute has?(html, "[data-setup-item=embed] a")
      assert has?(html, ~s(button[phx-value-id="embed"][aria-checked="true"]))
    end

    test "ticks stored for removed items neither show nor count" do
      old = user(%{dashboard_setup_done_items: ~w(theme meeting_types share)})
      html = render_checklist(user: old)

      assert rows(html) == ~w(calendar video avatar embed)
      assert html =~ "0/4"
    end
  end

  describe "accessible names" do
    test "the compact strip's toggle is named by the title and count it shows" do
      # An aria-label hid the visible text from voice control users and the
      # progress count from screen readers.
      html =
        render_component(&OnboardingChecklist.onboarding_checklist/1,
          integration_status: @no_integrations,
          current_user: user(),
          profile: profile(),
          variant: :compact
        )

      doc = Floki.parse_fragment!(html)

      assert [summary] = Floki.find(doc, "summary")
      assert Floki.attribute(summary, "aria-label") == []
      assert Floki.text(summary) =~ "0/4"
      assert Floki.text(summary) =~ "Finish setting up"
    end

    test "the full card is labelled by its visible heading" do
      html =
        render_component(&OnboardingChecklist.onboarding_checklist/1,
          integration_status: @no_integrations,
          current_user: user(),
          profile: profile()
        )

      doc = Floki.parse_fragment!(html)

      assert [section] = Floki.find(doc, "section[data-testid=onboarding-checklist]")
      assert Floki.attribute(section, "aria-label") == []
      assert Floki.attribute(section, "aria-labelledby") == ["onboarding-checklist-title"]

      assert doc |> Floki.find("#onboarding-checklist-title") |> Floki.text() =~
               "Finish setting up"
    end
  end
end
