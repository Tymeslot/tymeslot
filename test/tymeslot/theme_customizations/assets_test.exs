defmodule Tymeslot.ThemeCustomizations.AssetsTest do
  @moduledoc """
  `attach_asset/4`: store the upload, save it on the theme's customisation,
  queue video transcoding, and say what went wrong in the user's language.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :themes
  @moduletag :integration

  import Mox

  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Storage
  alias Tymeslot.Workers.VideoTranscoder

  setup :verify_on_exit!

  setup do
    upload_root =
      Path.join(System.tmp_dir!(), "tymeslot_assets_#{System.unique_integer([:positive])}")

    original_root = Application.get_env(:tymeslot, :upload_directory)
    Application.put_env(:tymeslot, :upload_directory, upload_root)

    on_exit(fn ->
      Application.put_env(:tymeslot, :upload_directory, original_root)
      File.rm_rf(upload_root)
    end)

    %{profile: insert(:profile)}
  end

  defp temp_file(name, contents) do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{name}")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    %{path: path, filename: name}
  end

  defp stored_file(profile, theme_id, relative) do
    full = Storage.build_theme_file_path("themes/#{profile.id}/#{theme_id}/#{relative}")
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "old")
    {"themes/#{profile.id}/#{theme_id}/#{relative}", full}
  end

  # Every file under the profile's upload directory for the theme, images and
  # videos alike.
  defp uploaded_files(profile, theme_id) do
    [Storage.get_upload_base_directory(), "themes", to_string(profile.id), theme_id, "*", "*"]
    |> Path.join()
    |> Path.wildcard()
  end

  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, "IHDR", 0x00,
         0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
         0xDE>>
  @mp4 <<0x00, 0x00, 0x00, 0x18, "ftypisom", "fake video data">>

  describe "background image" do
    test "stores the file and makes it the custom image background", %{profile: profile} do
      assert {:ok, customization} =
               ThemeCustomizations.attach_asset(
                 profile.id,
                 "1",
                 :background_image_path,
                 temp_file("bg.png", @png)
               )

      assert customization.settings["background_type"] == "image"
      assert customization.settings["background_value"] == "custom"

      assert customization.settings["background_image_path"] =~
               ~r{^themes/#{profile.id}/1/images/}

      assert File.exists?(
               Storage.build_theme_file_path(customization.settings["background_image_path"])
             )
    end

    test "replaces an uploaded video, deleting its file", %{profile: profile} do
      {video, video_file} = stored_file(profile, "1", "videos/old.mp4")

      {:ok, _existing} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "background_type" => "video",
          "background_value" => "custom",
          "background_video_path" => video
        })

      assert {:ok, customization} =
               ThemeCustomizations.attach_asset(
                 profile.id,
                 "1",
                 :background_image_path,
                 temp_file("bg.png", @png)
               )

      assert customization.settings["background_video_path"] == nil
      refute File.exists?(video_file)
    end

    test "refuses a file that is not an image, saving nothing", %{profile: profile} do
      assert {:error, "Invalid image format. Please upload a valid image file."} =
               ThemeCustomizations.attach_asset(
                 profile.id,
                 "1",
                 :background_image_path,
                 temp_file("bg.png", "not an image")
               )

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
    end
  end

  describe "background video" do
    test "stores the file, marks it pending and queues transcoding", %{profile: profile} do
      stub(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      assert {:ok, customization} =
               ThemeCustomizations.attach_asset(
                 profile.id,
                 "2",
                 :background_video_path,
                 temp_file("clip.mp4", @mp4)
               )

      assert customization.settings["background_type"] == "video"
      assert customization.settings["background_value"] == "custom"
      assert customization.video_processing_status == %{"background_video_path" => "pending"}

      assert File.exists?(
               Storage.build_theme_file_path(customization.settings["background_video_path"])
             )

      assert_enqueued(
        worker: VideoTranscoder,
        args: %{
          theme_customization_id: customization.id,
          field: "background_video_path",
          video_path: customization.settings["background_video_path"]
        }
      )
    end

    test "replaces an uploaded image, deleting its file", %{profile: profile} do
      stub(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)
      {image, image_file} = stored_file(profile, "2", "images/old.png")

      {:ok, _existing} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "2", %{
          "background_type" => "image",
          "background_value" => "custom",
          "background_image_path" => image
        })

      assert {:ok, customization} =
               ThemeCustomizations.attach_asset(
                 profile.id,
                 "2",
                 :background_video_path,
                 temp_file("clip.mp4", @mp4)
               )

      assert customization.settings["background_image_path"] == nil
      refute File.exists?(image_file)
    end

    test "refuses a file that is not a video, saving nothing", %{profile: profile} do
      stub(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      assert {:error, "Invalid video format. Please upload a valid video file."} =
               ThemeCustomizations.attach_asset(
                 profile.id,
                 "2",
                 :background_video_path,
                 temp_file("clip.mp4", "not a video")
               )

      refute_enqueued(worker: VideoTranscoder)
      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "2") == nil
    end

    test "refuses up front when ffmpeg is missing, queueing and saving nothing",
         %{profile: profile} do
      stub(Tymeslot.Media.TranscoderMock, :available?, fn -> false end)

      assert {:error, message} =
               ThemeCustomizations.attach_asset(
                 profile.id,
                 "2",
                 :background_video_path,
                 temp_file("clip.mp4", @mp4)
               )

      assert message =~ "ffmpeg is not installed"
      refute_enqueued(worker: VideoTranscoder)
      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "2") == nil
    end
  end

  describe "two video fields on one theme" do
    # The fixture theme ("99") offers two videos of its own
    # (`FixtureThemeSpec.Clips`), as a theme with a host video beside its
    # background does: each upload is queued and reported under its field.
    test "each upload is marked pending and queued under its own field", %{profile: profile} do
      stub(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      assert {:ok, _intro} =
               ThemeCustomizations.attach_asset(
                 profile.id,
                 "99",
                 :fixture_intro_clip_path,
                 temp_file("intro.mp4", @mp4)
               )

      assert {:ok, customization} =
               ThemeCustomizations.attach_asset(
                 profile.id,
                 "99",
                 :fixture_outro_clip_path,
                 temp_file("outro.mp4", @mp4)
               )

      assert customization.video_processing_status == %{
               "fixture_intro_clip_path" => "pending",
               "fixture_outro_clip_path" => "pending"
             }

      assert [_intro_job, _outro_job] = all_enqueued(worker: VideoTranscoder)

      for field <- ["fixture_intro_clip_path", "fixture_outro_clip_path"] do
        assert_enqueued(
          worker: VideoTranscoder,
          args: %{
            theme_customization_id: customization.id,
            field: field,
            video_path: customization.settings[field]
          }
        )
      end
    end

    test "one clip finishing leaves the other clip's state as it is", %{profile: profile} do
      stub(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)
      stub(Tymeslot.Media.TranscoderMock, :transcode, fn _source, _output, _opts -> :ok end)

      {:ok, _intro} =
        ThemeCustomizations.attach_asset(
          profile.id,
          "99",
          :fixture_intro_clip_path,
          temp_file("intro.mp4", @mp4)
        )

      {:ok, customization} =
        ThemeCustomizations.attach_asset(
          profile.id,
          "99",
          :fixture_outro_clip_path,
          temp_file("outro.mp4", @mp4)
        )

      assert :ok =
               perform_job(VideoTranscoder, %{
                 "theme_customization_id" => customization.id,
                 "field" => "fixture_intro_clip_path",
                 "video_path" => customization.settings["fixture_intro_clip_path"]
               })

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "99").video_processing_status ==
               %{"fixture_intro_clip_path" => "completed", "fixture_outro_clip_path" => "pending"}
    end
  end

  describe "captions" do
    @vtt "WEBVTT\n\n00:00.000 --> 00:02.000\nHello\n"

    test "stores a WebVTT file under captions/ and saves it on its field", %{profile: profile} do
      assert {:ok, customization} =
               ThemeCustomizations.attach_asset(
                 profile.id,
                 "99",
                 :fixture_intro_captions_path,
                 temp_file("intro.vtt", @vtt)
               )

      path = customization.settings["fixture_intro_captions_path"]
      assert path =~ ~r"^themes/#{profile.id}/99/captions/[0-9a-f]{12}-intro\.vtt$"
      assert File.read!(Storage.build_theme_file_path(path)) == @vtt

      # Captions are served as they are: nothing is transcoded or tracked.
      refute_enqueued(worker: VideoTranscoder)
      assert customization.video_processing_status == %{}
    end

    test "refuses a file that is not WebVTT, saving nothing", %{profile: profile} do
      assert {:error, "Invalid captions file. Please upload a WebVTT (.vtt) file."} =
               ThemeCustomizations.attach_asset(
                 profile.id,
                 "99",
                 :fixture_intro_captions_path,
                 temp_file("intro.vtt", "1\n00:00:01,000 --> 00:00:02,000\nHello\n")
               )

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "99") == nil
      assert uploaded_files(profile, "99") == []
    end

    test "a replacement deletes the file it replaces", %{profile: profile} do
      {:ok, first} =
        ThemeCustomizations.attach_asset(
          profile.id,
          "99",
          :fixture_intro_captions_path,
          temp_file("intro.vtt", @vtt)
        )

      {:ok, second} =
        ThemeCustomizations.attach_asset(
          profile.id,
          "99",
          :fixture_intro_captions_path,
          temp_file("intro.vtt", @vtt)
        )

      first_path = first.settings["fixture_intro_captions_path"]
      refute first_path == second.settings["fixture_intro_captions_path"]
      refute File.exists?(Storage.build_theme_file_path(first_path))

      assert File.exists?(
               Storage.build_theme_file_path(second.settings["fixture_intro_captions_path"])
             )
    end
  end

  describe "a save that is refused" do
    # The save of an upload's own changes can no longer be refused by the
    # spec (`Specs.settings/2` reads a stale row with the stale group's
    # defaults), but the database can still refuse it: here the profile is
    # gone, as when it is deleted while an upload is in flight, so the insert
    # fails on its foreign key.
    setup %{profile: profile} do
      missing = %{profile | id: profile.id + 1_000_000}

      # The premise: this profile's saves are refused.
      assert {:error, _changeset} =
               ThemeCustomizations.upsert_theme_customization(missing.id, "1", %{
                 "background_value" => "gradient_2"
               })

      %{profile: missing}
    end

    test "deletes the image it stored", %{profile: profile} do
      assert {:error, "Could not save your theme customisation. Please try again."} =
               ThemeCustomizations.attach_asset(
                 profile.id,
                 "1",
                 :background_image_path,
                 temp_file("bg.png", @png)
               )

      assert uploaded_files(profile, "1") == []
    end

    test "deletes the video it stored and queues nothing", %{profile: profile} do
      stub(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      assert {:error, "Could not save your theme customisation. Please try again."} =
               ThemeCustomizations.attach_asset(
                 profile.id,
                 "1",
                 :background_video_path,
                 temp_file("clip.mp4", @mp4)
               )

      assert uploaded_files(profile, "1") == []
      refute_enqueued(worker: VideoTranscoder)
    end

    test "leaves every other file, including one another tab has just stored",
         %{profile: profile} do
      # Referenced by nothing yet, like an upload in flight in a second tab.
      {_path, other_tab} = stored_file(profile, "1", "images/0123456789ab-other.png")

      assert {:error, _message} =
               ThemeCustomizations.attach_asset(
                 profile.id,
                 "1",
                 :background_image_path,
                 temp_file("bg.png", @png)
               )

      assert uploaded_files(profile, "1") == [other_tab]
    end
  end

  describe "fields the theme does not declare" do
    test "are refused", %{profile: profile} do
      assert {:error, "This option is not available for this theme."} =
               ThemeCustomizations.attach_asset(profile.id, "1", :logo, temp_file("l.png", @png))

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
    end

    test "are refused in the user's language", %{profile: profile} do
      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        assert {:error, "Diese Option ist für dieses Design nicht verfügbar."} =
                 ThemeCustomizations.attach_asset(
                   profile.id,
                   "1",
                   :logo,
                   temp_file("l.png", @png)
                 )
      end)
    end
  end

  describe "an unknown theme id" do
    test "is refused and stores no file", %{profile: profile} do
      assert {:error, "This option is not available for this theme."} =
               ThemeCustomizations.attach_asset(
                 profile.id,
                 "no-such-theme",
                 :background_image_path,
                 temp_file("bg.png", @png)
               )

      assert uploaded_files(profile, "no-such-theme") == []
      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "no-such-theme") == nil
    end
  end

  describe "asset_fields/1" do
    test "lists the upload columns the theme's spec declares" do
      assert ThemeCustomizations.asset_fields("1") ==
               [background_image_path: :image, background_video_path: :video]
    end
  end
end
