defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationBackgroundUploadTest do
  @moduledoc """
  Background choices that store or clear files, made through the theme
  customisation panel: uploading an image or a video, and picking a preset
  image or video, which drops any upload the previous background named.

  A successful upload pushes "upload-complete" so the `AutoUpload` hook clears
  the file picker, mirroring the avatar upload fixes (dashboard and
  onboarding), and what is published carries none of the uploaded file's
  metadata. Preset choices are clicked on the real buttons, so a picker that
  stopped sending `phx-value-choice` fails here.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :themes
  @moduletag :live

  import Mox
  import Tymeslot.DashboardTestHelpers

  alias Ecto.Changeset
  alias Phoenix.LiveComponent.CID
  alias Phoenix.LiveView
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Specs
  alias Tymeslot.ThemeCustomizations.Storage
  alias Tymeslot.Workers.VideoTranscoder
  alias TymeslotWeb.ThemeTestMatrix

  # Complete and decodable: a stored image is re-encoded, so magic bytes
  # alone are refused.
  @valid_png MediaFixtures.png()

  # A complete MP4: a stored video has its metadata stripped, which reads the
  # whole container, so magic bytes alone are refused.
  @valid_mp4 MediaFixtures.read!("gps.mp4")

  # The themes whose spec offers each kind, so a new theme is covered once it
  # does.
  @image_themes Enum.filter(
                  ThemeTestMatrix.all(),
                  &Specs.supports_background?(Specs.for_theme(&1.id), :image)
                )
  @video_themes Enum.filter(
                  ThemeTestMatrix.all(),
                  &Specs.supports_background?(Specs.for_theme(&1.id), :video)
                )

  # The loops below would pass untested over an empty list.
  if @image_themes == [] or @video_themes == [],
    do: raise("no theme in ThemeTestMatrix offers an image or a video background")

  setup :set_mox_global
  setup :verify_on_exit!
  setup :setup_dashboard_user_with_theme

  # The endpoint serves `/uploads` from the directory it finds on its first
  # request, cached in `:persistent_term`, and every request passes through
  # that plug. The cache is dropped on both sides of the swap, or whichever
  # test made the first request of the run would decide where every later
  # test's uploads are served from.
  @upload_static_key {TymeslotWeb.Endpoint, :upload_static_opts}

  defp isolated_upload_root(_context) do
    upload_root =
      Path.join(System.tmp_dir!(), "tymeslot_uploads_#{System.unique_integer([:positive])}")

    original_root = Application.get_env(:tymeslot, :upload_directory)
    Application.put_env(:tymeslot, :upload_directory, upload_root)
    :persistent_term.erase(@upload_static_key)

    on_exit(fn ->
      Application.put_env(:tymeslot, :upload_directory, original_root)
      :persistent_term.erase(@upload_static_key)
      File.rm_rf(upload_root)
    end)

    %{upload_root: upload_root}
  end

  defp stored_file(profile, theme_id, relative) do
    path = "themes/#{profile.id}/#{theme_id}/#{relative}"
    full = Storage.build_theme_file_path(path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "old")
    {path, full}
  end

  defp open_tab(conn, theme_id, kind) do
    {:ok, view, _html} = live(conn, "/dashboard/theme/customize/#{theme_id}")

    view
    |> element("button[phx-click='theme:set_browsing_type'][phx-value-type='#{kind}']")
    |> render_click()

    view
  end

  defp preset_button(field, choice),
    do:
      "button[phx-click='theme:set_option'][phx-value-option='background']" <>
        "[phx-value-field='#{field}'][phx-value-choice='#{choice}']"

  # A cleared upload is absent from the stored map rather than nil, so read
  # each key.
  defp background_settings(customization),
    do:
      Map.new(
        ~w(background_type background_value background_image_path background_video_path),
        &{&1, customization.settings[&1]}
      )

  defp video_entry do
    %{
      last_modified: System.system_time(:millisecond),
      name: "clip.mp4",
      content: @valid_mp4,
      type: "video/mp4"
    }
  end

  describe "background image upload" do
    setup :isolated_upload_root

    test "a successful upload pushes upload-complete so the AutoUpload hook clears the picker",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      view
      |> element("button[phx-value-theme='1']", "Customise Style")
      |> render_click()

      # Switch to the image tab, which renders the upload form.
      view
      |> element("button[phx-click='theme:set_browsing_type'][phx-value-type='image']")
      |> render_click()

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "background.png",
        content: @valid_png,
        type: "image/png"
      }

      view
      |> file_input("#theme-background-image-form", :background_image_path, [image])
      |> render_upload("background.png")

      assert_push_event(view, "upload-complete", %{})
    end

    test "an image upload replaces an uploaded video and removes its file",
         %{conn: conn, profile: profile} do
      video_rel = "themes/#{profile.id}/1/videos/old.mp4"
      video_abs = Storage.build_theme_file_path(video_rel)
      File.mkdir_p!(Path.dirname(video_abs))
      File.write!(video_abs, "data")

      {:ok, _customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", %{
          "color_scheme" => "default",
          "background_type" => "video",
          "background_value" => "custom",
          "background_video_path" => video_rel
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      view
      |> element("button[phx-value-theme='1']", "Customise Style")
      |> render_click()

      view
      |> element("button[phx-click='theme:set_browsing_type'][phx-value-type='image']")
      |> render_click()

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "background.png",
        content: @valid_png,
        type: "image/png"
      }

      view
      |> file_input("#theme-background-image-form", :background_image_path, [image])
      |> render_upload("background.png")

      assert_push_event(view, "upload-complete", %{})

      saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      assert saved.settings["background_type"] == "image"
      assert saved.settings["background_image_path"] =~ "themes/#{profile.id}/1/images/"
      assert saved.settings["background_video_path"] == nil
      refute File.exists?(video_abs)
    end

    test "publishes a WebP background without its EXIF location", %{
      conn: conn,
      profile: profile
    } do
      view = open_tab(conn, "1", "image")

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "garden.webp",
        content: MediaFixtures.read!("gps.webp"),
        type: "image/webp"
      }

      view
      |> file_input("#theme-background-image-form", :background_image_path, [image])
      |> render_upload("garden.webp")

      assert_push_event(view, "upload-complete", %{})

      customization = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      response = get(build_conn(), "/uploads/" <> customization.settings["background_image_path"])
      assert response.status == 200
      assert MediaFixtures.image_metadata_fields(response.resp_body) == []
      refute response.resp_body =~ "Model-X"
    end

    test "publishes a phone JPEG whose EXIF thumbnail pushes its dimensions past the first kilobytes",
         %{conn: conn, profile: profile} do
      view = open_tab(conn, "1", "image")

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "IMG_0042.JPG",
        content: MediaFixtures.read!("exif_thumbnail.jpg"),
        type: "image/jpeg"
      }

      view
      |> file_input("#theme-background-image-form", :background_image_path, [image])
      |> render_upload("IMG_0042.JPG")

      assert_push_event(view, "upload-complete", %{})

      customization = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      assert customization.settings["background_image_path"] =~ ~r/IMG_0042\.jpg\z/
      response = get(build_conn(), "/uploads/" <> customization.settings["background_image_path"])
      assert MediaFixtures.image_metadata_fields(response.resp_body) == []
    end

    test "refuses a file type it does not take, in words", %{conn: conn, profile: profile} do
      view = open_tab(conn, "1", "image")

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "moving.gif",
        content: MediaFixtures.read!("animated.gif"),
        type: "image/gif"
      }

      view
      |> file_input("#theme-background-image-form", :background_image_path, [image])
      |> render_upload("moving.gif")

      assert render(view) =~
               "This file type is not supported. Please upload a JPG, PNG or WebP image."

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
    end

    test "refuses an image over 40 megapixels and says how large it may be", %{
      conn: conn,
      profile: profile
    } do
      view = open_tab(conn, "1", "image")

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "huge.png",
        content: MediaFixtures.png_declaring(20_000, 20_000),
        type: "image/png"
      }

      view
      |> file_input("#theme-background-image-form", :background_image_path, [image])
      |> render_upload("huge.png")

      assert render(view) =~
               "This image is too large (400.0 megapixels). " <>
                 "Please upload an image of at most 40 megapixels."

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
    end
  end

  describe "preset backgrounds" do
    setup :isolated_upload_root

    for theme <- @image_themes do
      test "#{theme.name}: a preset image card saves it and clears the uploaded files",
           %{conn: conn, profile: profile} do
        theme_id = unquote(theme.id)
        {image, image_file} = stored_file(profile, theme_id, "images/old.png")
        {video, video_file} = stored_file(profile, theme_id, "videos/old.mp4")

        {:ok, _customization} =
          ThemeCustomizations.create_theme_customization(profile.id, theme_id, %{
            "background_type" => "image",
            "background_value" => "custom",
            "background_image_path" => image,
            "background_video_path" => video
          })

        [choice | _others] = Presets.get_image_presets() |> Map.keys() |> Enum.sort()
        view = open_tab(conn, theme_id, "image")

        view |> element(preset_button("image", choice)) |> render_click()

        saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, theme_id)

        assert background_settings(saved) ==
                 %{
                   "background_type" => "image",
                   "background_value" => choice,
                   "background_image_path" => nil,
                   "background_video_path" => nil
                 }

        refute File.exists?(image_file)
        refute File.exists?(video_file)
      end
    end

    for theme <- @video_themes do
      test "#{theme.name}: a preset video card saves it and clears the uploaded files",
           %{conn: conn, profile: profile} do
        theme_id = unquote(theme.id)
        {video, video_file} = stored_file(profile, theme_id, "videos/old.mp4")

        {:ok, _customization} =
          ThemeCustomizations.create_theme_customization(profile.id, theme_id, %{
            "background_type" => "video",
            "background_value" => "custom",
            "background_video_path" => video
          })

        # A preset other than the theme's default, so the save is observable.
        [choice | _others] =
          Presets.get_video_presets()
          |> Map.keys()
          |> Enum.reject(&(&1 == Specs.for_theme(theme_id).defaults()[:background_value]))
          |> Enum.sort()

        view = open_tab(conn, theme_id, "video")

        view |> element(preset_button("video", choice)) |> render_click()

        saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, theme_id)

        assert background_settings(saved) ==
                 %{
                   "background_type" => "video",
                   "background_value" => choice,
                   "background_image_path" => nil,
                   "background_video_path" => nil
                 }

        refute File.exists?(video_file)
      end
    end
  end

  describe "background video upload" do
    setup :isolated_upload_root

    for theme <- @video_themes do
      test "#{theme.name}: stores the video and queues its transcoding",
           %{conn: conn, profile: profile} do
        stub(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)
        theme_id = unquote(theme.id)
        view = open_tab(conn, theme_id, "video")

        view
        |> file_input("#theme-background-video-form", :background_video_path, [video_entry()])
        |> render_upload("clip.mp4")

        assert_push_event(view, "upload-complete", %{})

        saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, theme_id)
        path = saved.settings["background_video_path"]

        assert saved.settings["background_type"] == "video"
        assert saved.settings["background_value"] == "custom"
        assert path =~ ~r"\Athemes/#{profile.id}/#{theme_id}/videos/[^/]+\.mp4\z"
        assert File.exists?(Storage.build_theme_file_path(path))

        assert_enqueued(
          worker: VideoTranscoder,
          args: %{theme_customization_id: saved.id, video_path: path}
        )
      end

      test "#{theme.name}: without ffmpeg, says so in the user's language and stores nothing",
           %{conn: conn, user: user, profile: profile, upload_root: upload_root} do
        stub(Tymeslot.Media.TranscoderMock, :available?, fn -> false end)
        user |> Changeset.change(locale: "de") |> Repo.update!()
        theme_id = unquote(theme.id)
        view = open_tab(conn, theme_id, "video")

        view
        |> file_input("#theme-background-video-form", :background_video_path, [video_entry()])
        |> render_upload("clip.mp4")

        assert render(view) =~ "weil ffmpeg nicht installiert ist"
        assert ThemeCustomizations.get_by_profile_and_theme(profile.id, theme_id) == nil
        refute_enqueued(worker: VideoTranscoder)
        refute File.exists?(Path.join(upload_root, "themes/#{profile.id}/#{theme_id}/videos"))
      end
    end

    test "refuses a QuickTime file", %{conn: conn} do
      view = open_tab(conn, hd(@video_themes).id, "video")

      video = %{
        last_modified: System.system_time(:millisecond),
        name: "clip.mov",
        content: <<0, 0, 0, 20, "ftypqt  ", 0, 0, 0, 0, "qt  ">>,
        type: "video/quicktime"
      }

      assert {:error, [[_ref, :not_accepted]]} =
               view
               |> file_input("#theme-background-video-form", :background_video_path, [video])
               |> render_upload("clip.mov")
    end
  end

  # LiveViewTest's `render_upload` never sends the form's `phx-change`, and the
  # progress callback consumes a finished entry first, so the `upload_asset`
  # handler is reached only by spending the budget, letting the progress-path
  # consume be refused, and then submitting the form.
  describe "the upload_asset handler" do
    setup :isolated_upload_root

    setup %{user: user} do
      bucket = "theme_upload:#{user.id}"
      RateLimiter.clear_bucket(bucket)
      on_exit(fn -> RateLimiter.clear_bucket(bucket) end)
      %{bucket: bucket}
    end

    test "consumes a finished entry the progress callback was refused",
         %{conn: conn, profile: profile, bucket: bucket} do
      for _i <- 1..5, do: assert(:ok = RateLimiter.check_rate_limit(bucket, 5, 600_000))

      view = open_tab(conn, "1", "image")

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "background.png",
        content: @valid_png,
        type: "image/png"
      }

      view
      |> file_input("#theme-background-image-form", :background_image_path, [image])
      |> render_upload("background.png")

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil

      RateLimiter.clear_bucket(bucket)
      view |> form("#theme-background-image-form") |> render_submit()

      assert_push_event(view, "upload-complete", _payload)

      saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      assert saved.settings["background_type"] == "image"
      assert saved.settings["background_image_path"] =~ "themes/#{profile.id}/1/images/"
    end

    # In the browser both triggers fire for one finished upload: the progress
    # callback, and the submit `AutoUpload` clicks, which LiveView sends once
    # the upload completes. The second reaches the LiveView before it has
    # handled the upload channel's exit, so the consumed entry still looks
    # finished. Holding the LiveView while both are queued reproduces that
    # order; consuming the entry again called into the stopped channel and
    # crashed the LiveView, after the file was saved.
    test "a second consume queued behind the first is a no-op",
         %{conn: conn, profile: profile, bucket: bucket} do
      for _i <- 1..5, do: assert(:ok = RateLimiter.check_rate_limit(bucket, 5, 600_000))

      view = open_tab(conn, "1", "image")

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "background.png",
        content: @valid_png,
        type: "image/png"
      }

      view
      |> file_input("#theme-background-image-form", :background_image_path, [image])
      |> render_upload("background.png")

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
      RateLimiter.clear_bucket(bucket)

      [cid] =
        Regex.run(
          ~r/data-phx-component="(\d+)"/,
          view |> element("#theme-customization-uploads") |> render(),
          capture: :all_but_first
        )

      :sys.suspend(view.pid)

      for _i <- 1..2 do
        LiveView.send_update(view.pid, %CID{cid: String.to_integer(cid)},
          consume_upload: :background_image_path
        )
      end

      :sys.resume(view.pid)

      assert render(view) =~ "You have a custom image."
      assert Process.alive?(view.pid)

      saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      assert saved.settings["background_image_path"] =~ "themes/#{profile.id}/1/images/"
    end

    test "a field the theme does not declare saves nothing",
         %{conn: conn, profile: profile} do
      view = open_tab(conn, "1", "image")

      view |> form("#theme-background-image-form") |> render_change(%{"asset_field" => "bogus"})

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
    end
  end
end
