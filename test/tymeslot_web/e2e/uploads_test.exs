defmodule TymeslotWeb.E2E.UploadsTest do
  @moduledoc """
  File uploads picked in a real browser: the profile avatar and a theme's
  background image (auto-upload forms, saved once the file arrives) and the
  self-host admin's email logo, which the `EmailLogoUpload` hook rasterises to
  a PNG in the browser before uploading it.

  Each test gets an upload root of its own (`Tymeslot.Test.UploadRoot`), so
  stored files land in a temporary directory that is removed afterwards, and
  `/uploads` serves from it.
  """
  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :profiles
  @moduletag :emails

  import ExUnit.CaptureLog
  import Tymeslot.TestHelpers.Eventually

  alias Tymeslot.AppSettings
  alias Tymeslot.Profiles
  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.Test.UploadRoot
  alias Tymeslot.ThemeCustomizations

  @avatar_input "#avatar-upload-form input[type='file']"
  @avatar_img "#avatar-upload-section img"
  @logo_img "img[alt='Current email logo']"

  setup do
    UploadRoot.isolate("tymeslot_e2e_uploads")
    :ok
  end

  describe "profile avatar" do
    feature "a picked image uploads on its own, is stored and replaces the initials", %{
      session: session
    } do
      {session, user} = log_in_via_browser(session)
      profile = Profiles.get_profile(user.id)
      assert profile.avatar == nil

      session =
        session
        |> visit("/dashboard/settings")
        |> wait_for_live()
        |> assert_has(css(@avatar_img))

      assert avatar_src(session) =~ "data:"

      session
      |> attach_file(css(@avatar_input, visible: false), path: MediaFixtures.path("gps.png"))
      |> assert_has(css("#app-flash-group-info", text: "Avatar updated successfully"))

      avatar = eventually(fn -> Profiles.get_profile(user.id).avatar end, timeout: 5_000)
      stored = UploadRoot.path(Path.join(["avatars", to_string(profile.id), avatar]))

      assert File.regular?(stored)
      assert MediaFixtures.image_dimensions(File.read!(stored)) == {32, 16}

      src = "/uploads/avatars/#{profile.id}/#{avatar}"
      eventually(fn -> avatar_src(session) == src end, timeout: 5_000)
      assert_image_loaded(session, @avatar_img)
    end

    feature "a file that is not an image is refused and nothing is stored", %{session: session} do
      {session, user} = log_in_via_browser(session)

      session
      |> visit("/dashboard/settings")
      |> wait_for_live()
      |> assert_has(css(@avatar_img))
      |> attach_file(css(@avatar_input, visible: false),
        path: MediaFixtures.path("not_an_image.txt")
      )
      |> assert_has(css("#avatar-upload-container", text: "Not accepted"))

      assert Profiles.get_profile(user.id).avatar == nil
      assert avatar_src(session) =~ "data:"
    end
  end

  describe "theme background image" do
    feature "a picked image is saved once, without crashing the page", %{session: session} do
      {session, user} = log_in_via_browser(session)
      profile = Profiles.get_profile(user.id)

      session =
        session
        |> visit("/dashboard/pages/customize/1")
        |> wait_for_live()
        |> click(css("button[phx-click='theme:set_browsing_type'][phx-value-type='image']"))

      # A second save of the same finished upload calls into its stopped
      # upload channel and crashes the LiveView after the file is stored, so
      # the stored file alone cannot tell one save from two; the crash report
      # can.
      log =
        capture_log(fn ->
          session
          |> attach_file(css("#theme-background-image-form input[type='file']", visible: false),
            path: MediaFixtures.path("gps.png")
          )
          |> assert_has(
            css("#app-flash-group-info", text: "Background image uploaded successfully")
          )

          # A round trip after the save: the LiveView handles events in order,
          # so any second trigger of the save has been handled once this
          # click's result shows.
          session
          |> click(css("button[phx-click='theme:set_browsing_type'][phx-value-type='gradient']"))
          |> assert_has(
            css(
              "button[phx-click='theme:set_option'][phx-value-option='background'][phx-value-field='gradient']",
              minimum: 1
            )
          )
        end)

      refute log =~ "terminating"

      stored =
        eventually(
          fn ->
            ThemeCustomizations.get_by_profile_and_theme(profile.id, "1").settings[
              "background_image_path"
            ]
          end,
          timeout: 5_000
        )

      assert File.regular?(UploadRoot.path(stored))
      assert File.ls!(Path.dirname(UploadRoot.path(stored))) == [Path.basename(stored)]
    end
  end

  describe "admin email logo" do
    setup :restore_logo_setting

    feature "a picked JPEG is converted to a PNG, stored and previewed", %{session: session} do
      {session, _admin} = log_in_via_browser(session, %{is_admin: true})

      session
      |> visit("/admin/email")
      |> wait_for_live()
      |> refute_has(css(@logo_img))
      |> attach_file(css("#email-logo-picker"),
        path: MediaFixtures.path("exif_thumbnail.jpg")
      )
      |> assert_has(css("#app-flash-group-info", text: "Email logo updated."))
      |> assert_has(css(@logo_img))

      relative = eventually(fn -> AppSettings.get(:email_logo_path) end, timeout: 5_000)
      stored = File.read!(UploadRoot.path(relative))

      # The server accepts only a PNG, so a stored file at all says the hook
      # converted the JPEG; the size says it drew it at its own 32x16 rather
      # than scaled up to the 300px render width.
      assert <<137, 80, 78, 71, 13, 10, 26, 10, _rest::binary>> = stored
      assert MediaFixtures.image_dimensions(stored) == {32, 16}

      assert evaluate_script(
               session,
               "return document.querySelector(\"#{@logo_img}\").getAttribute('src');"
             ) ==
               "/uploads/" <> relative

      assert_image_loaded(session, @logo_img)
    end

    feature "a file the browser cannot read as an image is refused", %{session: session} do
      {session, _admin} = log_in_via_browser(session, %{is_admin: true})

      session
      |> visit("/admin/email")
      |> wait_for_live()
      |> attach_file(css("#email-logo-picker"), path: MediaFixtures.path("not_an_image.png"))
      |> assert_has(
        css("#app-flash-group-error", text: "That image could not be read. Try a PNG or JPEG.")
      )
      |> refute_has(css(@logo_img))

      assert AppSettings.get(:email_logo_path) == nil
    end
  end

  # Storing a logo writes the setting to the database and to the application
  # environment, which `AppSettings.get/1` reads. The row goes with the
  # sandbox; the environment outlives the test, so it is put back here.
  # (`AppSettingsEnvHelpers` cannot be used: it clears the row in `on_exit`,
  # after the browser test's sandbox owner has gone.)
  defp restore_logo_setting(_context) do
    original = Application.fetch_env(:tymeslot, :email_logo_path)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:tymeslot, :email_logo_path, value)
        :error -> Application.delete_env(:tymeslot, :email_logo_path)
      end
    end)
  end

  defp avatar_src(session) do
    evaluate_script(
      session,
      "return document.querySelector(\"#{@avatar_img}\").getAttribute('src');"
    )
  end

  # The image was fetched and decoded, not just given a src: a 404 from
  # `/uploads` leaves `naturalWidth` at 0.
  defp assert_image_loaded(session, selector) do
    eventually(
      fn ->
        evaluate_script(session, """
        const img = document.querySelector("#{selector}");
        return img.complete && img.naturalWidth > 0;
        """)
      end,
      timeout: 5_000,
      message: "#{selector} never loaded its image"
    )
  end
end
