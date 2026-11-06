defmodule TymeslotWeb.OnboardingLive.LivePreviewTest do
  use ExUnit.Case, async: true

  @moduletag :onboarding
  @moduletag :components

  import Phoenix.LiveViewTest

  alias Tymeslot.Availability.WeekPreview
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias TymeslotWeb.OnboardingLive.LivePreview

  # Tuesday 3 November 2026: a week with Tuesday 14:00 busy and 23 slots.
  @busy_week %{
    state: :ready,
    preview: %WeekPreview{
      days: [
        %{date: ~D[2026-11-03], slots: ["09:00"], busy: [{~T[14:00:00], ~T[15:00:00]}]}
      ],
      slot_count: 23,
      first_busy: %{date: ~D[2026-11-03], start: ~T[14:00:00]}
    }
  }

  defp caption(step, week) do
    LivePreview.caption(%{
      current_step: step,
      booking_page_live: true,
      booking_host: "tymeslot.test",
      username: "ada",
      stage_week: week
    })
  end

  defp render_preview(settings) do
    render_component(&LivePreview.live_preview/1,
      current_step: :profile,
      booking_theme: "1",
      theme_customization: %ThemeCustomizationSchema{theme_id: "1", settings: settings},
      booking_host: "tymeslot.test",
      today: ~D[2026-11-03]
    )
  end

  test "draws with the theme's resolved colours, a custom seed included" do
    html =
      render_preview(%{
        "color_scheme" => "default",
        "custom_palette_seed" => "#123456",
        "background_type" => "gradient",
        "background_value" => "gradient_1"
      })

    assert html =~ "#123456"
    # The stored scheme's preset primary; the seed replaces the whole palette.
    refute html =~ "#06b6d4"
  end

  describe "a page that follows the visitor's OS" do
    defp paper(mode) do
      customization = %ThemeCustomizationSchema{
        theme_id: "3",
        settings: %{"color_scheme" => "paper_sunset", "colour_mode" => mode}
      }

      html =
        render_component(&LivePreview.live_preview/1,
          current_step: :ready,
          booking_theme: "3",
          theme_customization: customization,
          booking_host: "tymeslot.test",
          today: ~D[2026-11-03]
        )

      {html, LivePreview.canvas("3", customization)}
    end

    # The real page shows its dark set on a dark system, so the miniature it
    # replaces on the live step must too, or the page changes as it loads.
    test "draws both colour sets, for the system to choose between" do
      {html, canvas} = paper("auto")

      [root_style] =
        html |> Floki.parse_fragment!() |> Floki.attribute("div", "style") |> Enum.take(1)

      assert root_style =~ "color-scheme: light dark"
      assert root_style =~ "light-dark("
      assert canvas =~ ~r/^light-dark\(#\w+, #\w+\)$/
    end

    test "draws one set for a page fixed to light" do
      {html, canvas} = paper("light")

      refute html =~ "light-dark("
      refute html =~ "color-scheme"
      assert canvas =~ ~r/^#\w+$/
    end
  end

  test "draws a preset scheme with that preset's colours" do
    html =
      render_preview(%{
        "color_scheme" => "sunset",
        "background_type" => "gradient",
        "background_value" => "gradient_1"
      })

    assert html =~ "#f97316"
  end

  describe "caption/1" do
    test "the caption names the first busy block" do
      assert caption(:connect_calendar, @busy_week) ==
               "Your Tuesday 02:00 PM is already blocked. 23 open slots this week."
    end

    test "without a busy block it counts the open slots, in the singular for one" do
      free = put_in(@busy_week.preview.first_busy, nil)

      assert caption(:meeting, free) == "23 open slots this week."

      assert caption(:meeting, put_in(free.preview.slot_count, 1)) ==
               "1 open slot this week."
    end

    test "a week that is not ready has no caption" do
      for state <- [:placeholder, :loading, :slow, :failed] do
        assert caption(:connect_calendar, %{state: state, preview: nil}) == nil
      end
    end

    test "never announces a page without a username as live" do
      caption =
        LivePreview.caption(%{
          current_step: :ready,
          booking_page_live: true,
          booking_host: "tymeslot.test",
          username: "  ",
          stage_week: @busy_week
        })

      assert caption == nil
    end

    test "the last step keeps the live page's caption" do
      assert caption(:ready, @busy_week) == "You're all set: tymeslot.test/ada is live"
    end
  end

  describe "the address on the card" do
    test "keeps the username whole, in an element of its own apart from the host" do
      html =
        render_component(&LivePreview.live_preview/1,
          current_step: :profile,
          booking_theme: "3",
          username: "a-rather-long-username",
          booking_host: "localhost:4000",
          today: ~D[2026-11-03]
        )

      doc = Floki.parse_fragment!(html)

      assert [chip] = Floki.find(doc, "[data-role='preview-address']")

      assert chip |> Floki.text() |> String.replace(~r/\s+/, "") ==
               "localhost:4000/a-rather-long-username"

      # The host may give way on a narrow card; the name is never split.
      assert [name] = Floki.find(chip, "[data-role='preview-address-name']")
      assert String.trim(Floki.text(name)) == "a-rather-long-username"
    end
  end

  describe "the host's picture on the card" do
    defp header(theme, attrs) do
      html =
        render_component(
          &LivePreview.live_preview/1,
          [
            current_step: :profile,
            booking_theme: theme,
            booking_host: "tymeslot.test",
            today: ~D[2026-11-03]
          ] ++ attrs
        )

      Floki.parse_fragment!(html)
    end

    test "is the host's initials, from the name as typed, while there is no photo" do
      for theme <- ~w(1 2 3 4) do
        doc = header(theme, name: "maya okafor")

        assert [initials] = Floki.find(doc, "[data-role='preview-initials']"), "theme #{theme}"
        assert String.trim(Floki.text(initials)) == "MO"
      end
    end

    test "is drawn on the theme's own primary colour" do
      [initials] = Floki.find(header("1", name: "Ada"), "[data-role='preview-initials']")
      [quill] = Floki.attribute(initials, "style")
      [initials] = Floki.find(header("4", name: "Ada"), "[data-role='preview-initials']")
      [paper] = Floki.attribute(initials, "style")

      assert quill =~ "color: #ffffff"
      assert quill != paper
    end

    test "is the photo once there is one" do
      doc = header("1", name: "Maya Okafor", avatar_url: "/uploads/avatars/maya.webp")

      assert Floki.find(doc, "[data-role='preview-initials']") == []
      assert Floki.attribute(doc, "img[src='/uploads/avatars/maya.webp']", "src") != []
    end

    test "is a person outline before a name is typed" do
      [initials] = Floki.find(header("1", name: "  "), "[data-role='preview-initials']")

      assert String.trim(Floki.text(initials)) == ""
      assert Floki.find(initials, "svg") != []
    end
  end

  describe "initials/1" do
    test "takes the first and last names' first letters, or the only name's" do
      assert LivePreview.initials("maya okafor") == "MO"
      assert LivePreview.initials("Ana María de la Cruz") == "AC"
      assert LivePreview.initials("Prince") == "P"
      assert LivePreview.initials("élodie") == "É"
      assert LivePreview.initials("") == nil
      assert LivePreview.initials(nil) == nil
    end
  end

  describe "a 24-hour locale" do
    test "names the busy day in German and keeps the 24-hour clock" do
      caption =
        Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
          caption(:connect_calendar, @busy_week)
        end)

      assert caption =~ "Dienstag"
      assert caption =~ "14:00"
      refute caption =~ "PM"
    end

    test "draws the day's times and busy block in German" do
      html =
        Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
          render_component(&LivePreview.live_preview/1,
            current_step: :connect_calendar,
            booking_theme: "2",
            booking_host: "tymeslot.test",
            week: @busy_week,
            today: ~D[2026-11-03]
          )
        end)

      doc = Floki.parse_fragment!(html)
      assert doc |> Floki.find("[data-preview-part='days']") |> Floki.text() =~ "Di"
      assert doc |> Floki.find("[data-entry='busy']") |> Floki.text() =~ "14:00 – 15:00"
      assert doc |> Floki.find("[data-entry='slot']") |> Floki.text() =~ "09:00"
      refute html =~ "AM"
    end
  end

  describe "the step highlight" do
    defp ringed(step) do
      render_component(&LivePreview.live_preview/1,
        current_step: step,
        booking_theme: "1",
        booking_host: "tymeslot.test",
        week: @busy_week,
        today: ~D[2026-11-03]
      )
      |> Floki.parse_fragment!()
      |> Floki.find("[data-stage-focus]")
      |> Enum.flat_map(&Floki.attribute(&1, "data-preview-region"))
    end

    test "the calendar step rings the calendar area and the meeting step the times" do
      assert ringed(:connect_calendar) == ["calendar"]
      assert ringed(:meeting) == ["slots"]
    end

    test "choosing a theme and the last step ring nothing on the page" do
      assert ringed(:choose_theme) == []
      assert ringed(:ready) == []
      assert ringed(:profile) == []
    end
  end

  describe "the identity on a phone" do
    test "is one compact row below sm, and leaves each theme's layout alone from sm" do
      identity =
        render_preview(%{})
        |> Floki.parse_fragment!()
        |> Floki.find("[data-role='preview-identity']")

      assert [row] = identity
      assert [class] = Floki.attribute(row, "class")
      # `contents` from sm: the theme lays out the avatar, name and address
      # as before; below sm one flex row.
      assert class =~ "contents"
      assert class =~ "max-sm:flex"
      assert Floki.find(row, "[data-preview-avatar]") != []
      assert Floki.find(row, "[data-role='preview-address']") != []
    end
  end
end
