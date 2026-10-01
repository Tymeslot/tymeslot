defmodule TymeslotWeb.Themes.ThemeOpennessTest do
  @moduledoc """
  A new theme attaches by adding files and one registry entry. The fixture
  theme (`test/support/fixture_theme/`, registered by `config/test.exs`) is
  shaped unlike Quill and Rhythm on purpose: a light palette with no presets,
  no background, and an option group, a dashboard panel and an event of its
  own. Each test below drives one of those through the real routes; the last
  one checks that no shared code names it, so none of this works by a
  special case.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :integration

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.ThemeBookingFlowHelpers

  alias Tymeslot.Onboarding
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Test.FixtureThemeSpec
  alias Tymeslot.Test.FixtureThemeSpec.Emblem
  alias Tymeslot.TestMocks
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Specs
  alias Tymeslot.ThemeCustomizations.Storage
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panels
  alias TymeslotWeb.Test.FixtureTheme.EmblemPanel
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @theme_id "99"

  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, "IHDR", 0x00,
         0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
         0xDE>>

  # Everything the test-only themes add that a shared module could name,
  # their ids among them as quoted literals.
  @fixture_names ~r/FixtureTheme|fixture_emblem|EmblemPanel|:fixture\b|ShowcaseTheme|:showcase\b|#{Regex.escape(~s("99"))}|#{Regex.escape(~s("97"))}/

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  defp booking_page(conn, username) do
    %{profile: profile} = seed_booking_account(@theme_id, username, "UTC")
    {:ok, view, html} = live(conn, ~p"/#{profile.username}")
    %{view: view, html: html, profile: profile}
  end

  describe "the booking page" do
    test "renders in the theme's own wrapper and steps", %{conn: conn} do
      %{view: view} = booking_page(conn, "fixture-page")

      assert has_element?(view, ".fixture-theme-wrapper [data-testid='fixture-overview']")
      assert has_element?(view, "[data-testid='duration-option']", "Quick Chat")
      refute has_element?(view, "#background-motion-toggle")
    end

    test "writes the light palette, and its dark counterpart for a dark OS", %{conn: conn} do
      %{html: html} = booking_page(conn, "fixture-palette")

      assert html =~ "--fixture-emblem-radius: 999px;"
      assert html =~ "--theme-primary:"
      assert html =~ "--theme-canvas:"
      assert html =~ "@media (prefers-color-scheme: dark)"
    end

    test "moves between the theme's own steps", %{conn: conn} do
      %{view: view} = booking_page(conn, "fixture-steps")

      view |> element("[data-testid='duration-option']") |> render_click()
      view |> element("[data-testid='next-step']") |> render_click()
      assert has_element?(view, "[data-testid='fixture-schedule']")

      view |> element("[data-testid='back-step']") |> render_click()
      assert has_element?(view, "[data-testid='fixture-overview']")
    end
  end

  describe "the theme's own event" do
    test "reaches its handle_theme_event/3 from a step template", %{conn: conn} do
      %{view: view} = booking_page(conn, "fixture-ping")
      refute has_element?(view, "[data-testid='fixture-pinged']")

      view |> element("[data-testid='fixture-ping']") |> render_click()

      assert has_element?(view, "[data-testid='fixture-pinged']")
    end

    # Any visitor can send any `theme:` event; one the theme does not handle
    # falls through to the catch-all clause of the fixture's own hook
    # (test/support/fixture_theme/live.ex). `defoverridable` replaces the
    # default hook wholesale, so this pins that clause, not the default one.
    test "leaves the page working when the theme does not know the event", %{conn: conn} do
      %{view: view} = booking_page(conn, "fixture-unknown")

      view
      |> with_target("[data-testid='fixture-overview']")
      |> render_click("theme:no_such_event", %{"x" => "1"})

      assert Process.alive?(view.pid)
      refute has_element?(view, "[data-testid='fixture-pinged']")

      view |> element("[data-testid='fixture-ping']") |> render_click()
      assert has_element?(view, "[data-testid='fixture-pinged']")
    end

    test "is not reached by the same name without the theme: prefix from a step template",
         %{conn: conn} do
      %{view: view} = booking_page(conn, "fixture-unprefixed")

      view |> with_target("[data-testid='fixture-overview']") |> render_click("ping", %{})

      refute has_element?(view, "[data-testid='fixture-pinged']")
    end

    # Pins today's behaviour: SchedulingLive hands any event it does not handle
    # itself to handle_theme_event/3, prefix or not, so an untargeted "ping"
    # reaches the hook. Only the step-template path filters on `theme:`.
    test "is reached by the same name sent to the LiveView itself", %{conn: conn} do
      %{view: view} = booking_page(conn, "fixture-toplevel")
      refute has_element?(view, "[data-testid='fixture-pinged']")

      render_click(view, "ping", %{})

      assert has_element?(view, "[data-testid='fixture-pinged']")
    end
  end

  describe "the theme's own option" do
    setup %{conn: conn} do
      {:ok, ctx} = setup_dashboard_user_with_theme(%{conn: conn}, @theme_id)
      Map.new(ctx)
    end

    # The branch of `Panels.for_group/2` no shipped theme reaches: the
    # theme's own `option_panels/0` wins.
    test "gets its panel from the theme's option_panels/0" do
      assert Panels.for_group(@theme_id, Specs.group(FixtureThemeSpec, Emblem)) == EmblemPanel
    end

    test "gets the theme's own panel in the dashboard, beside the shared palette", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/dashboard/theme/customize/#{@theme_id}")

      assert has_element?(view, "[data-testid='fixture-emblem-panel']")
      assert html =~ "Colour Palette"
      refute html =~ "Background Design"
    end

    test "saves through its panel", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme/customize/#{@theme_id}")

      view
      |> element(
        "[data-testid='fixture-emblem-panel'] button[phx-value-option='emblem'][phx-value-choice='square']"
      )
      |> render_click()

      saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, @theme_id)
      assert saved.settings["fixture_emblem_shape"] == "square"
      refute Map.has_key?(saved.settings, "background_type")

      assert has_element?(
               view,
               "[data-testid='fixture-emblem-panel'] button[phx-value-choice='square'][aria-pressed='true']"
             )
    end

    test "reaches the booking page once saved", %{conn: conn} do
      %{profile: profile} = seed_booking_account(@theme_id, "fixture-saved-shape", "UTC")

      assert {:ok, _saved} =
               ThemeCustomizations.apply_option(profile.id, @theme_id, :emblem, %{
                 "field" => "shape",
                 "value" => "square"
               })

      {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

      assert html =~ "--fixture-emblem-radius: 0;"
    end

    test "refuses a value outside the group's own choices", %{profile: profile} do
      assert {:error, _message} =
               ThemeCustomizations.apply_option(profile.id, @theme_id, :emblem, %{
                 "field" => "shape",
                 "value" => "oval"
               })

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, @theme_id) == nil
    end
  end

  describe "the theme's own upload" do
    setup do
      upload_root =
        Path.join(System.tmp_dir!(), "tymeslot_openness_#{System.unique_integer([:positive])}")

      original_root = Application.get_env(:tymeslot, :upload_directory)
      Application.put_env(:tymeslot, :upload_directory, upload_root)

      on_exit(fn ->
        Application.put_env(:tymeslot, :upload_directory, original_root)
        File.rm_rf(upload_root)
      end)

      path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-emblem.png")
      File.write!(path, @png)
      on_exit(fn -> File.rm(path) end)

      %{upload: %{path: path, filename: "emblem.png"}}
    end

    test "is stored for its group and shown on the booking page", %{conn: conn, upload: upload} do
      %{profile: profile} = seed_booking_account(@theme_id, "fixture-emblem", "UTC")

      assert {:ok, saved} =
               ThemeCustomizations.attach_asset(
                 profile.id,
                 @theme_id,
                 :fixture_emblem_path,
                 upload
               )

      assert saved.settings["fixture_emblem_path"] =~ ~r{^themes/#{profile.id}/99/images/}
      refute Map.has_key?(saved.settings, "background_type")

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      assert has_element?(
               view,
               "img[data-testid='fixture-emblem'][src='/uploads/#{saved.settings["fixture_emblem_path"]}']"
             )
    end

    test "a second upload replaces the first and deletes its file", %{upload: upload} do
      %{profile: profile} = seed_booking_account(@theme_id, "fixture-emblem-twice", "UTC")

      {:ok, first} =
        ThemeCustomizations.attach_asset(profile.id, @theme_id, :fixture_emblem_path, upload)

      File.write!(upload.path, @png)

      {:ok, second} =
        ThemeCustomizations.attach_asset(profile.id, @theme_id, :fixture_emblem_path, upload)

      first_path = first.settings["fixture_emblem_path"]
      second_path = second.settings["fixture_emblem_path"]

      assert first_path != second_path
      refute File.exists?(Storage.build_theme_file_path(first_path))
      assert File.exists?(Storage.build_theme_file_path(second_path))
    end

    test "uploads through the theme's own panel in the dashboard", %{conn: conn} do
      {:ok, ctx} = setup_dashboard_user_with_theme(%{conn: conn}, @theme_id)
      %{conn: conn, profile: profile} = Map.new(ctx)
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme/customize/#{@theme_id}")

      emblem = %{
        last_modified: System.system_time(:millisecond),
        name: "emblem.png",
        content: @png,
        type: "image/png"
      }

      view
      |> file_input("#fixture-emblem-upload", :fixture_emblem_path, [emblem])
      |> render_upload("emblem.png")

      assert_push_event(view, "upload-complete", %{})

      saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, @theme_id)
      assert saved.settings["fixture_emblem_path"] =~ ~r{^themes/#{profile.id}/99/images/}
      refute Map.has_key?(saved.settings, "background_type")
    end

    # `render_upload/2` consumes through the progress callback (above). To reach
    # the panel form's `upload_asset` handler instead, the progress callback's
    # consume is refused by an exhausted rate limit (the entry stays done),
    # then the limit is cleared and the form submitted.
    test "saves through the panel form's upload_asset event", %{conn: conn} do
      {:ok, ctx} = setup_dashboard_user_with_theme(%{conn: conn}, @theme_id)
      %{conn: conn, profile: profile, user: user} = Map.new(ctx)
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme/customize/#{@theme_id}")

      bucket = "theme_upload:#{user.id}"
      on_exit(fn -> RateLimiter.clear_bucket(bucket) end)
      for _attempt <- 1..5, do: RateLimiter.check_rate_limit(bucket, 5, 600_000)

      emblem = %{
        last_modified: System.system_time(:millisecond),
        name: "emblem.png",
        content: @png,
        type: "image/png"
      }

      view
      |> file_input("#fixture-emblem-upload", :fixture_emblem_path, [emblem])
      |> render_upload("emblem.png")

      refute match?(
               %{settings: %{"fixture_emblem_path" => _path}},
               ThemeCustomizations.get_by_profile_and_theme(profile.id, @theme_id)
             )

      RateLimiter.clear_bucket(bucket)

      view
      |> form("#fixture-emblem-upload", %{"asset_field" => "fixture_emblem_path"})
      |> render_submit()

      assert_push_event(view, "upload-complete", %{})

      saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, @theme_id)
      assert saved.settings["fixture_emblem_path"] =~ ~r{^themes/#{profile.id}/99/images/}
      refute Map.has_key?(saved.settings, "background_type")
    end
  end

  describe "a theme without a background" do
    test "offers no video preset, so onboarding seeds it no preview video" do
      assert ThemeCustomizations.video_preset_keys(@theme_id) == []

      %{profile: profile} = seed_booking_account(@theme_id, "fixture-onboarding", "UTC")
      assert :ok = Onboarding.ensure_preview_video_backgrounds(profile, ["1", @theme_id])

      assert %{settings: %{"background_type" => "video"}} =
               ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, @theme_id) == nil
    end
  end

  describe "the pickers" do
    test "offer no beta theme, though its id is valid" do
      assert ThemeInfo.valid_theme_id?(@theme_id)
      refute Enum.any?(ThemeInfo.theme_options(), fn {_name, id} -> id == @theme_id end)
    end
  end

  describe "shared code" do
    # A source check: it reads the shared code rather than calling it.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "names nothing the fixture theme adds" do
      shared = Path.wildcard("lib/**/*.{ex,exs,heex}")
      configs = Path.wildcard("config/*.exs") -- ["config/test.exs"]
      files = ["mix.exs" | shared ++ configs]

      # The two directories the openness goal names must be among those read.
      assert Enum.any?(shared, &String.starts_with?(&1, "lib/tymeslot/theme_customizations/"))
      assert Enum.any?(shared, &String.starts_with?(&1, "lib/tymeslot_web/themes/shared/"))

      naming = Enum.filter(files, &(File.read!(&1) =~ @fixture_names))

      assert naming == [], "shared code names a test-only theme: #{inspect(naming)}"
    end
  end
end
