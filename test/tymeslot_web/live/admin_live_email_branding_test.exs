defmodule TymeslotWeb.AdminLiveEmailBrandingTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :live
  @moduletag :emails

  import Phoenix.LiveViewTest
  import Tymeslot.AppSettingsEnvHelpers
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.AppSettings
  alias Tymeslot.Emails.Branding
  alias Tymeslot.Emails.Shared.Styles.Tokens

  # A 1x1 PNG — the browser hook converts before upload, so the server side
  # only ever needs to accept a PNG.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup :restore_app_settings_env

  setup %{conn: conn} do
    original_router = Application.get_env(:tymeslot, :router)
    Application.put_env(:tymeslot, :router, TymeslotWeb.Router)
    Application.put_env(:tymeslot, :enable_admin_ui, true)

    on_exit(fn ->
      if original_router,
        do: Application.put_env(:tymeslot, :router, original_router),
        else: Application.delete_env(:tymeslot, :router)

      Application.put_env(:tymeslot, :enable_admin_ui, true)
      Branding.remove_logo()
    end)

    admin = insert(:user, is_admin: true)
    {:ok, conn: log_in_user(conn, admin), admin: admin}
  end

  defp accent_form(lv) do
    form(lv, "#admin-setting-hex-form-email_brand_accent")
  end

  describe "accent colour" do
    test "the section renders with the three branding controls", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/settings")

      assert html =~ "Email branding"
      assert html =~ "Email accent colour"
      assert html =~ "Email brand name"
      assert html =~ "Email logo"
    end

    test "saving a hex colour persists it and changes the email tokens", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      html =
        lv
        |> accent_form()
        |> render_submit(%{"key" => "email_brand_accent", "value" => "#7c3aed"})

      assert html =~ "Email accent colour updated."
      assert AppSettings.get(:email_brand_accent) == "#7c3aed"
      assert %{accent: "#7c3aed"} = Tokens.intent(:confirmed)
    end

    test "an uppercase hex is normalised before it is stored", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      render_submit(accent_form(lv), %{"key" => "email_brand_accent", "value" => "#7C3AED"})

      assert AppSettings.get(:email_brand_accent) == "#7c3aed"
    end

    test "a non-colour is rejected with a usable message and stores nothing", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      html =
        lv
        |> accent_form()
        |> render_submit(%{"key" => "email_brand_accent", "value" => "turquoise-ish"})

      assert html =~ "Enter a hex colour such as #14b8a6."
      assert AppSettings.get(:email_brand_accent) == nil
    end

    test "clearing the field restores the stock turquoise", %{conn: conn} do
      {:ok, _settings} = AppSettings.update(%{email_brand_accent: "#7c3aed"})
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      render_submit(accent_form(lv), %{"key" => "email_brand_accent", "value" => ""})

      assert AppSettings.get(:email_brand_accent) == nil
      assert %{accent: "#14b8a6"} = Tokens.intent(:confirmed)
    end

    test "a low-contrast colour renders a warning rather than being rejected", %{conn: conn} do
      {:ok, _settings} = AppSettings.update(%{email_brand_accent: "#f5d90a"})

      {:ok, _lv, html} = live(conn, ~p"/admin/settings")

      assert html =~ "Buttons may be hard to read."
      assert AppSettings.get(:email_brand_accent) == "#f5d90a"
    end

    test "a colour with adequate contrast renders no warning", %{conn: conn} do
      {:ok, _settings} = AppSettings.update(%{email_brand_accent: "#0f172a"})

      {:ok, _lv, html} = live(conn, ~p"/admin/settings")

      refute html =~ "Buttons may be hard to read."
    end

    test "picking the swatch does not autosave, and a stale hex submit can't be raced by it",
         %{conn: conn} do
      {:ok, _settings} = AppSettings.update(%{email_brand_accent: "#123456"})
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      # Simulate the swatch commit that used to write straight to
      # `AppSettings` on blur.
      html =
        lv
        |> form("#admin-setting-form-email_brand_accent")
        |> render_change(%{"value" => "#abcdef"})

      # The pick is a preview only - nothing is persisted, and the hex field
      # mirrors it so the admin sees what they just picked.
      assert AppSettings.get(:email_brand_accent) == "#123456"
      assert html =~ "value=\"#abcdef\""

      # The hex form is the sole writer. Submitting it with a value from
      # before the swatch pick (the "stale DOM" the race used to exploit)
      # commits deterministically instead of the two forms racing.
      render_submit(accent_form(lv), %{"key" => "email_brand_accent", "value" => "#123456"})

      # The submitted hex matches what is stored, so this is the unchanged
      # path: acknowledged with the saved pulse rather than an "updated" flash.
      assert_push_event(lv, "ts:setting-saved", %{key: "email_brand_accent"})
      assert AppSettings.get(:email_brand_accent) == "#123456"
    end

    test "the hex form has an accessible name and the swatch/hex controls describe the feedback region",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/settings")

      assert html =~
               ~s(id="admin-setting-hex-form-email_brand_accent" phx-submit="save_setting" class="flex items-center gap-2" aria-label="Set Email accent colour")

      assert html =~ ~s(id="setting-swatch-email_brand_accent")
      assert html =~ ~s(aria-describedby="email-brand-accent-feedback")
      assert html =~ ~s(id="email-brand-accent-feedback" aria-live="polite")
    end
  end

  describe "brand name" do
    test "saving a name persists it and feeds the email copy", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      html =
        lv
        |> form("#admin-setting-form-email_brand_name")
        |> render_submit(%{"key" => "email_brand_name", "value" => "Beaver Dental"})

      assert html =~ "Email brand name updated."
      assert Branding.brand_name() == "Beaver Dental"
    end

    test "an over-long name is rejected", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      html =
        lv
        |> form("#admin-setting-form-email_brand_name")
        |> render_submit(%{"key" => "email_brand_name", "value" => String.duplicate("a", 61)})

      assert html =~ "That value is too long."
      assert Branding.brand_name() == "Tymeslot"
    end

    test "submitting the built-in default unchanged still acknowledges the save", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      html =
        lv
        |> form("#admin-setting-form-email_brand_name")
        |> render_submit(%{"key" => "email_brand_name", "value" => "Tymeslot"})

      assert_push_event(lv, "ts:setting-saved", %{key: "email_brand_name"})
      refute html =~ "Email brand name updated."
      assert Branding.brand_name() == "Tymeslot"
    end
  end

  describe "logo upload" do
    test "an uploaded PNG is stored and previewed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      logo = file_input(lv, "#admin-email-logo-form", :email_logo, [entry(@png)])

      assert render_upload(logo, "email-logo.png") =~ "Email logo updated."

      relative = AppSettings.get(:email_logo_path)
      assert String.starts_with?(relative, "branding/")
      assert render(lv) =~ "/uploads/" <> relative
    end

    test "bytes that are not a PNG are rejected and nothing is stored", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      logo =
        file_input(lv, "#admin-email-logo-form", :email_logo, [
          entry("this is not an image at all")
        ])

      assert render_upload(logo, "email-logo.png") =~
               "That file is not a valid image and was not saved."

      assert AppSettings.get(:email_logo_path) == nil
    end

    test "removing the logo clears the setting and the preview", %{conn: conn} do
      path = Path.join(System.tmp_dir!(), "admin-live-logo-#{System.unique_integer([:positive])}")
      File.write!(path, @png)
      {:ok, _relative} = Branding.store_logo(path)

      {:ok, lv, html} = live(conn, ~p"/admin/settings")
      assert html =~ "/uploads/branding/"

      html = lv |> element("button[phx-click='remove_email_logo']") |> render_click()

      assert html =~ "Email logo removed."
      refute html =~ "/uploads/branding/"
      assert AppSettings.get(:email_logo_path) == nil
    end

    test "the browser reports a conversion failure without storing anything", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      html = render_hook(lv, "email_logo_conversion_failed", %{})

      assert html =~ "That image could not be read."
      assert AppSettings.get(:email_logo_path) == nil
    end

    test "the hook reports an oversized source before it reaches the server", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      html = render_hook(lv, "email_logo_too_large", %{})

      assert html =~ "That image is too large. Pick one under 2 MB."
      assert AppSettings.get(:email_logo_path) == nil
    end

    test "an entry rejected by the framework's own size limit is surfaced, not silent",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      oversized = :binary.copy(<<0>>, 2_000_001)
      logo = file_input(lv, "#admin-email-logo-form", :email_logo, [entry(oversized)])

      # An entry over `max_file_size` is refused at preflight, so the upload
      # never runs and `render_upload/2` reports the rejection instead of
      # returning markup; the message reaches the admin on the next render.
      assert {:error, [[_ref, :too_large]]} = render_upload(logo, "email-logo.png")
      assert render(lv) =~ "That image is too large. Pick one under 2 MB."

      assert AppSettings.get(:email_logo_path) == nil
    end

    test "the upload control has a visible focus state and the errors are announced",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/settings")

      assert html =~ "focus-within:ring-2"
      assert html =~ ~s(aria-describedby="email-logo-errors")
      assert html =~ ~s(id="email-logo-errors" aria-live="polite")
    end
  end

  defp entry(content) do
    %{
      last_modified: 1_594_171_879_000,
      name: "email-logo.png",
      content: content,
      size: byte_size(content),
      type: "image/png"
    }
  end
end
