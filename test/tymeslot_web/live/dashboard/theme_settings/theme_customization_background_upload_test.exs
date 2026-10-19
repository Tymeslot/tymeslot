defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationBackgroundUploadTest do
  @moduledoc """
  Background choices that store or clear files, made through the theme
  customisation panel: uploading an image or a video, and picking a preset
  image or video. An uploaded image and an uploaded video both stay stored,
  whatever is shown, until that same upload is replaced or removed.

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
  alias Tymeslot.Media.Transcoder
  alias Tymeslot.Repo
  alias Tymeslot.Test.JobRefusal
  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.Test.UploadRoot
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Specs
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

  defp isolated_upload_root(_context), do: %{upload_root: UploadRoot.isolate()}

  defp stored_file(profile, theme_id, relative) do
    path = "themes/#{profile.id}/#{theme_id}/#{relative}"
    full = UploadRoot.path(path)
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

  defp tab_button(kind),
    do: "button[phx-click='theme:set_browsing_type'][phx-value-type='#{kind}']"

  defp saved_settings(profile),
    do: ThemeCustomizations.get_by_profile_and_theme(profile.id, "1").settings

  defp shown(profile) do
    settings = saved_settings(profile)
    {settings["background_type"], settings["background_value"]}
  end

  defp served?(path), do: get(build_conn(), "/uploads/" <> path).status == 200

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

    test "an image upload becomes the background and keeps the uploaded video stored",
         %{conn: conn, profile: profile} do
      video_rel = "themes/#{profile.id}/1/videos/old.mp4"
      video_abs = UploadRoot.path(video_rel)
      File.mkdir_p!(Path.dirname(video_abs))
      File.write!(video_abs, "data")

      {:ok, _customization} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
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
      assert saved.settings["background_video_path"] == video_rel
      assert File.exists?(video_abs)
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
      assert customization.settings["background_image_path"] =~ ~r/\.jpg\z/
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
      test "#{theme.name}: a preset image card saves it and keeps both uploads stored",
           %{conn: conn, profile: profile} do
        theme_id = unquote(theme.id)
        {image, image_file} = stored_file(profile, theme_id, "images/old.png")
        {video, video_file} = stored_file(profile, theme_id, "videos/old.mp4")

        {:ok, _customization} =
          ThemeCustomizations.upsert_theme_customization(profile.id, theme_id, %{
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
                   "background_image_path" => image,
                   "background_video_path" => video
                 }

        assert File.exists?(image_file)
        assert File.exists?(video_file)
      end
    end

    for theme <- @video_themes do
      test "#{theme.name}: a preset video card saves it and keeps the uploaded video stored",
           %{conn: conn, profile: profile} do
        theme_id = unquote(theme.id)
        {video, video_file} = stored_file(profile, theme_id, "videos/old.mp4")

        {:ok, _customization} =
          ThemeCustomizations.upsert_theme_customization(profile.id, theme_id, %{
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
                   "background_video_path" => video
                 }

        assert File.exists?(video_file)
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
        assert served?(path)

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

    test "when the video cannot be queued, says the upload failed and keeps the previous video",
         %{conn: conn, profile: profile, upload_root: upload_root} do
      stub(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)
      theme_id = hd(@video_themes).id
      {previous, previous_file} = stored_file(profile, theme_id, "videos/previous.mp4")

      {:ok, _row} =
        ThemeCustomizations.upsert_theme_customization(profile.id, theme_id, %{
          "background_type" => "video",
          "background_value" => "custom",
          "background_video_path" => previous
        })

      JobRefusal.refuse_jobs(VideoTranscoder)
      view = open_tab(conn, theme_id, "video")

      view
      |> file_input("#theme-background-video-form", :background_video_path, [video_entry()])
      |> render_upload("clip.mp4")

      assert render(view) =~ "The upload failed and nothing was changed. Please try again."

      saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, theme_id)
      assert saved.settings["background_video_path"] == previous
      assert saved.video_processing_status == %{}
      refute_enqueued(worker: VideoTranscoder)

      assert Path.wildcard(Path.join(upload_root, "themes/#{profile.id}/#{theme_id}/videos/*")) ==
               [previous_file]
    end

    test "stores a video under its detected type, replaces the previous one with its variants, and transcodes the new one",
         %{conn: conn, profile: profile} do
      stub(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)
      theme_id = hd(@video_themes).id
      view = open_tab(conn, theme_id, "video")

      # A WebM sent under an MP4 name is stored as what it is.
      webm = %{video_entry() | content: MediaFixtures.read!("gps.webm")}

      view
      |> file_input("#theme-background-video-form", :background_video_path, [webm])
      |> render_upload("clip.mp4")

      assert_push_event(view, "upload-complete", %{})

      first = ThemeCustomizations.get_by_profile_and_theme(profile.id, theme_id)
      first_path = first.settings["background_video_path"]
      assert Path.basename(first_path) =~ ~r/\A[0-9a-f-]{36}\.webm\z/
      assert first.video_processing_status == %{"background_video_path" => "pending"}

      # What the first video's transcode wrote beside it.
      first_variants =
        for variant <- Transcoder.derive_variant_paths(first_path) do
          path = UploadRoot.path(variant)
          File.write!(path, "variant")
          path
        end

      view
      |> file_input("#theme-background-video-form", :background_video_path, [video_entry()])
      |> render_upload("clip.mp4")

      assert_push_event(view, "upload-complete", %{})

      second = ThemeCustomizations.get_by_profile_and_theme(profile.id, theme_id)
      second_path = second.settings["background_video_path"]
      assert Path.extname(second_path) == ".mp4"
      refute served?(first_path)
      refute Enum.any?(first_variants, &File.exists?/1)

      args = %{
        "theme_customization_id" => second.id,
        "field" => "background_video_path",
        "video_path" => second_path
      }

      assert_enqueued(worker: VideoTranscoder, args: args)

      expect(
        Tymeslot.Media.TranscoderMock,
        :transcode,
        length(Transcoder.variant_definitions()),
        fn _src, _out, _opts -> :ok end
      )

      assert :ok = perform_job(VideoTranscoder, args)

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, theme_id).video_processing_status ==
               %{"background_video_path" => "completed"}
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
  describe "switching between uploads and removing them" do
    setup :isolated_upload_root

    # Quill offers both an image and a video background.
    test "both uploads stay until removed, and either can be shown again without a new upload",
         %{conn: conn, profile: profile} do
      stub(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)
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

      view |> element(tab_button("video")) |> render_click()

      view
      |> file_input("#theme-background-video-form", :background_video_path, [video_entry()])
      |> render_upload("clip.mp4")

      %{"background_image_path" => image_path, "background_video_path" => video_path} =
        saved_settings(profile)

      # A preset image is shown; both uploads stay served.
      view |> element(tab_button("image")) |> render_click()
      [preset | _others] = Presets.get_image_presets() |> Map.keys() |> Enum.sort()
      view |> element(preset_button("image", preset)) |> render_click()

      assert served?(image_path)
      assert served?(video_path)

      # Back to the uploaded image, then the uploaded video, without uploading again.
      view |> element("[data-testid='show-uploaded-image']") |> render_click()
      assert shown(profile) == {"image", "custom"}

      view |> element(tab_button("video")) |> render_click()
      view |> element("[data-testid='show-uploaded-video']") |> render_click()
      assert shown(profile) == {"video", "custom"}

      # Removing the image, not on show, deletes only it.
      view |> element(tab_button("image")) |> render_click()
      view |> element("[data-testid='remove-uploaded-image']") |> render_click()

      assert shown(profile) == {"video", "custom"}
      refute served?(image_path)
      assert served?(video_path)
      refute has_element?(view, "[data-testid='uploaded-image']")

      # The organiser stays on the tab they removed it from, though the
      # background on show is a video.
      assert has_element?(view, "#theme-background-image-form")

      # Removing the video on show falls back to the theme's default background.
      view |> element(tab_button("video")) |> render_click()
      view |> element("[data-testid='remove-uploaded-video']") |> render_click()

      assert shown(profile) == {"gradient", "gradient_1"}
      refute served?(video_path)
      assert has_element?(view, "#theme-background-video-form")

      assert Map.take(saved_settings(profile), ["background_image_path", "background_video_path"]) ==
               %{}
    end
  end
end
