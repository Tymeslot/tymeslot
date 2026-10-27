defmodule Tymeslot.ThemeCustomizations.Options.BackgroundTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.Utils.ChangesetErrors

  @all_kinds [:gradient, :color, :image, :video]

  defp group(kinds),
    do: %{
      key: :background,
      module: Background,
      kinds: kinds,
      gradients: ["gradient_1", "gradient_4"],
      images: ["preset:ocean-sunset"],
      videos: ["preset:space"]
    }

  defp changeset(attrs, kinds \\ @all_kinds) do
    {%{}, Background.types()}
    |> Changeset.change()
    |> Background.changeset(attrs, group(kinds))
  end

  defp error(cs, field), do: cs.errors |> Keyword.get(field) |> elem(0)

  describe "changeset/3 colour" do
    test "stores a three-digit colour as lower-case #rrggbb" do
      cs = changeset(%{"background_type" => "color", "background_value" => "#FFF"})

      assert cs.valid?
      assert Changeset.get_change(cs, :background_value) == "#ffffff"
    end

    test "rejects the alpha form and non-hex colours" do
      for value <- ["#ff550080", "rgb(255, 0, 0)", "transparent"] do
        cs = changeset(%{"background_type" => "color", "background_value" => value})
        assert error(cs, :background_value) == "must be a hex colour such as #14b8a6", value
      end
    end
  end

  describe "changeset/3 kinds" do
    test "rejects a kind the theme does not offer" do
      cs =
        changeset(
          %{"background_type" => "video", "background_value" => "preset:space"},
          [:gradient, :color]
        )

      assert error(cs, :background_type) == "is not supported by this theme"
    end

    test "rejects an unknown kind" do
      assert error(changeset(%{"background_type" => "plaid"}), :background_type) == "is invalid"
    end
  end

  describe "changeset/3 presets and uploads" do
    test "rejects an unknown gradient" do
      cs = changeset(%{"background_type" => "gradient", "background_value" => "gradient_99"})
      assert error(cs, :background_value) == "must be a valid gradient preset"
    end

    test "says what is wrong in the organiser's language" do
      cs = changeset(%{"background_type" => "video", "background_value" => "custom"})

      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        assert ChangesetErrors.translate(cs.errors[:background_video_path]) ==
                 "ist für ein hochgeladenes Hintergrundvideo erforderlich"
      end)
    end

    test "rejects an unknown image or video preset" do
      image = changeset(%{"background_type" => "image", "background_value" => "preset:nope"})
      video = changeset(%{"background_type" => "video", "background_value" => "preset:nope"})

      assert error(image, :background_value) == "must be a valid image preset"
      assert error(video, :background_value) == "must be a valid video preset"
    end

    test "rejects a shipped preset the group does not list" do
      gradient = changeset(%{"background_type" => "gradient", "background_value" => "gradient_2"})

      image =
        changeset(%{"background_type" => "image", "background_value" => "preset:space-satellite"})

      video = changeset(%{"background_type" => "video", "background_value" => "preset:blue-wave"})

      assert error(gradient, :background_value) == "must be a valid gradient preset"
      assert error(image, :background_value) == "must be a valid image preset"
      assert error(video, :background_value) == "must be a valid video preset"
    end

    test "requires the stored path for an uploaded video" do
      cs = changeset(%{"background_type" => "video", "background_value" => "custom"})
      assert error(cs, :background_video_path) == "is required for an uploaded video background"
    end

    test "accepts a known preset without a path" do
      assert changeset(%{
               "background_type" => "image",
               "background_value" => "preset:ocean-sunset"
             }).valid?
    end
  end

  describe "changes/3" do
    test "sets the kind and value" do
      assert {:ok, %{"background_type" => "color", "background_value" => "#ff5500"}} =
               Background.changes("color", "#ff5500", group(@all_kinds))
    end

    test "never names an upload, whatever is chosen" do
      for {kind, value} <- [
            {"gradient", "gradient_1"},
            {"color", "#ff5500"},
            {"image", "preset:artistic-studio"},
            {"video", "preset:blue-wave"},
            {"image", "custom"},
            {"video", "custom"}
          ] do
        assert {:ok, changes} = Background.changes(kind, value, group(@all_kinds))

        assert changes == %{"background_type" => kind, "background_value" => value},
               "#{kind}/#{value}"
      end
    end

    test "refuses a kind the group does not offer" do
      assert Background.changes("video", "preset:space", group([:gradient, :color])) == :error
    end
  end

  describe "presets/2" do
    test "the group's presets of one kind, in the group's order" do
      assert [{"gradient_1", %{name: "Aurora"}}, {"gradient_4", %{name: "Forest"}}] =
               Background.presets(group(@all_kinds), :gradient)
    end

    test "nothing for a kind the group lists no presets of" do
      assert Background.presets(%{key: :background, module: Background, kinds: [:color]}, :video) ==
               []
    end
  end

  describe "descriptor/1" do
    test "a gradient resolves to the preset's CSS" do
      assert Background.descriptor(%{
               "background_type" => "gradient",
               "background_value" => "gradient_1"
             }) ==
               %{kind: :gradient, css: "linear-gradient(135deg, #667eea 0%, #764ba2 100%)"}
    end

    test "an invalid colour resolves to nothing" do
      assert Background.descriptor(%{
               "background_type" => "color",
               "background_value" => "</style><script>"
             }) == nil
    end

    test "an uploaded image is addressed under /uploads with its path sanitised" do
      assert Background.descriptor(%{
               "background_type" => "image",
               "background_value" => "custom",
               "background_image_path" => "themes/1/1/images/../a b.jpg"
             }) == %{kind: :image, url: "/uploads/themes/1/1/images/ab.jpg"}
    end

    test "an uploaded video keeps every dot of its name in the variant paths" do
      %{kind: :video, sources: sources} =
        Background.descriptor(%{
          "background_type" => "video",
          "background_value" => "custom",
          "background_video_path" => "videos/my.video.file.mp4"
        })

      srcs = Enum.map(sources, & &1.src)

      assert "/uploads/videos/my.video.file-desktop.webm" in srcs
      assert List.last(srcs) == "/uploads/videos/my.video.file.mp4"
    end

    test "an uploaded video path is sanitised before it reaches a source" do
      %{kind: :video, sources: sources} =
        Background.descriptor(%{
          "background_type" => "video",
          "background_value" => "custom",
          "background_video_path" => "videos/<script>alert(1)</script>.mp4"
        })

      assert sources != []

      for %{src: src} <- sources do
        refute src =~ "<"
        refute src =~ "("
      end
    end

    test "an image preset chosen beside a kept upload shows the preset" do
      assert Background.descriptor(%{
               "background_type" => "image",
               "background_value" => "preset:ocean-sunset",
               "background_image_path" => "themes/1/1/images/kept.png"
             }) == %{kind: :image, url: "/images/themes/backgrounds/ocean-sunset.webp"}
    end

    test "a video preset chosen beside a kept upload plays the preset" do
      %{kind: :video, sources: sources, poster: poster} =
        Background.descriptor(%{
          "background_type" => "video",
          "background_value" => "preset:space",
          "background_video_path" => "themes/1/1/videos/kept.mp4"
        })

      srcs = Enum.map(sources, & &1.src)
      assert srcs != []
      assert Enum.all?(srcs, &String.starts_with?(&1, "/videos/backgrounds/"))
      assert is_binary(poster) and poster =~ "/images/ui/posters/"
    end

    test "an unknown video preset has no sources and no poster" do
      assert Background.descriptor(%{
               "background_type" => "video",
               "background_value" => "preset:nope"
             }) == %{kind: :video, sources: [], poster: nil}
    end
  end

  describe "vars/2" do
    test "a gradient or colour is the --theme-background itself" do
      assert Background.vars(%{kind: :color, color: "#abcdef"}, %{}) ==
               %{"--theme-background" => "#abcdef"}

      assert Background.vars(%{kind: :gradient, css: "linear-gradient(red, blue)"}, %{}) ==
               %{"--theme-background" => "linear-gradient(red, blue)"}
    end

    test "behind a video the palette's canvas shows" do
      video = %{kind: :video, sources: [], poster: nil}

      assert Background.vars(video, %{"--theme-canvas" => "#0f172a"}) ==
               %{"--theme-background" => "var(--theme-canvas)"}
    end

    test "with neither a painted background nor a palette, nothing is emitted" do
      assert Background.vars(nil, %{}) == %{}
    end
  end

  describe "tokens/4" do
    test "adds the painted background over what came before" do
      acc = %{vars: %{"--theme-canvas" => "#0f172a"}, dark_vars: %{"--theme-text" => "#ffffff"}}
      settings = %{"background_type" => "gradient", "background_value" => "gradient_1"}

      assert Background.tokens(settings, %{}, acc, group(@all_kinds)) == %{
               vars: %{
                 "--theme-canvas" => "#0f172a",
                 "--theme-background" => "linear-gradient(135deg, #667eea 0%, #764ba2 100%)"
               },
               dark_vars: %{"--theme-text" => "#ffffff"}
             }
    end

    test "behind an image, shows the canvas the groups before it produced" do
      acc = %{vars: %{"--theme-canvas" => "#0f172a"}, dark_vars: %{}}
      settings = %{"background_type" => "image", "background_value" => "preset:ocean-sunset"}

      assert Background.tokens(settings, %{}, acc, group(@all_kinds)).vars["--theme-background"] ==
               "var(--theme-canvas)"
    end

    test "adds nothing behind an image when nothing before it made a canvas" do
      acc = %{vars: %{}, dark_vars: %{}}
      settings = %{"background_type" => "image", "background_value" => "preset:ocean-sunset"}

      assert Background.tokens(settings, %{}, acc, group(@all_kinds)) == acc
    end
  end

  describe "asset_fields/1" do
    test "names both upload columns and their kinds when the group offers both" do
      assert Background.asset_fields(group(@all_kinds)) == [
               background_image_path: :image,
               background_video_path: :video
             ]
    end

    test "leaves out the upload of a kind the group does not offer" do
      assert Background.asset_fields(group([:gradient, :image])) == [
               background_image_path: :image
             ]

      assert Background.asset_fields(group([:gradient, :color])) == []
    end
  end

  describe "media/2" do
    test "is the descriptor, under :background" do
      settings = %{"background_type" => "gradient", "background_value" => "gradient_2"}

      assert %{background: %{kind: :gradient} = descriptor} =
               Background.media(settings, group(@all_kinds))

      assert descriptor == Background.descriptor(settings)
    end

    test "holds nil when nothing resolves" do
      settings = %{"background_type" => "gradient", "background_value" => "gradient_999"}

      assert Background.media(settings, group(@all_kinds)) == %{background: nil}
    end
  end

  describe "upload_changes/3" do
    test "an image upload becomes the custom image background and leaves the video alone" do
      assert Background.upload_changes(
               :background_image_path,
               "themes/1/1/images/a.png",
               group(@all_kinds)
             ) ==
               %{
                 "background_type" => "image",
                 "background_value" => "custom",
                 "background_image_path" => "themes/1/1/images/a.png"
               }
    end

    test "a video upload becomes the custom video background and leaves the image alone" do
      assert Background.upload_changes(
               :background_video_path,
               "themes/1/1/videos/a.mp4",
               group(@all_kinds)
             ) ==
               %{
                 "background_type" => "video",
                 "background_value" => "custom",
                 "background_video_path" => "themes/1/1/videos/a.mp4"
               }
    end
  end

  describe "removal_changes/3" do
    @defaults %{"background_type" => "gradient", "background_value" => "gradient_1"}

    test "removing the upload on show falls back to the theme's default background" do
      settings = %{
        "background_type" => "image",
        "background_value" => "custom",
        "background_image_path" => "themes/1/1/images/a.png",
        "background_video_path" => "themes/1/1/videos/a.mp4"
      }

      assert Background.removal_changes(:background_image_path, settings, @defaults) == %{
               "background_image_path" => nil,
               "background_type" => "gradient",
               "background_value" => "gradient_1"
             }
    end

    test "removing an upload not on show only clears it" do
      settings = %{
        "background_type" => "image",
        "background_value" => "custom",
        "background_image_path" => "themes/1/1/images/a.png",
        "background_video_path" => "themes/1/1/videos/a.mp4"
      }

      assert Background.removal_changes(:background_video_path, settings, @defaults) ==
               %{"background_video_path" => nil}
    end

    test "a preset of the same kind on show is not the upload" do
      settings = %{
        "background_type" => "video",
        "background_value" => "preset:blue-wave",
        "background_video_path" => "themes/1/1/videos/a.mp4"
      }

      assert Background.removal_changes(:background_video_path, settings, @defaults) ==
               %{"background_video_path" => nil}
    end
  end
end
